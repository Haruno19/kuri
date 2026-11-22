import Foundation
import KuriCore
import KuriInference
import KuriStore
import KuriTools

/// Limits that keep a turn from running away.
public struct TurnLimits: Sendable {
    /// Model requests per turn.
    public var maxRounds = 40
    /// The same tool with the same arguments, within one turn.
    public var maxIdenticalCalls = 3
    /// Characters of tool output passed back to the model.
    public var maxToolOutputCharacters = 30_000
    /// Compact when a request would fill this share of the context window.
    public var compactionThreshold = 0.75
    /// After compacting, what's kept verbatim should fit in this share.
    public var compactionKeepShare = 0.5

    public init() {}
}

/// Runs one turn: ask the model, run the tools it calls, repeat until it
/// answers without calling any.
struct TurnRunner {
    let conversationID: UUID
    let turn: Turn
    let provider: any InferenceProvider
    let modelConfig: ModelConfigSnapshot
    let instructions: String
    let folders: [ConversationFolder]
    let registry: ToolRegistry
    let store: Store
    let interaction: any UserInteraction
    let limits: TurnLimits
    /// Summarizes the conversation when it outgrows the context window.
    let compactor: Compactor?
    /// Messages the user sent while this turn was running, taken at each
    /// step boundary so they join the turn.
    var takeQueued: @Sendable () async -> [String] = { [] }
    /// False for models that can't be offered tools.
    var useTools = true
    let emit: @Sendable (EngineEvent) -> Void

    /// - Parameter resuming: The turn was waiting for the user when Kuri
    ///   quit. Its unanswered calls run again first — which asks again —
    ///   then the turn goes on as usual.
    func run(resuming: Bool = false) async -> TurnOutcome {
        var usage = Usage()
        let outcome: TurnOutcome
        do {
            let stop = try await loop(usage: &usage, resuming: resuming)
            outcome = .completed(stop)
            try? await store.finishTurn(turn.id, status: .completed, stopReason: stop, usage: usage)
        } catch is CancellationError {
            outcome = .cancelled
            try? await store.finishTurn(turn.id, status: .cancelled, stopReason: .cancelled, usage: usage)
        } catch {
            let message = error.localizedDescription
            outcome = .failed(message)
            try? await store.finishTurn(turn.id, status: .failed, stopReason: nil, usage: usage, error: message)
        }
        emit(.turnFinished(conversationID: conversationID, turnID: turn.id, outcome))
        return outcome
    }

    private func loop(usage: inout Usage, resuming: Bool) async throws -> StopReason {
        var callCounts: [String: Int] = [:]
        let interaction = TurnInteraction(base: interaction, store: store, turnID: turn.id)

        if resuming {
            let pending = Self.unansweredCalls(in: try await store.items(of: conversationID), turnID: turn.id)
            try await runCalls(pending, counts: &callCounts, interaction: interaction)
        }

        var compactionFailed = false
        for _ in 0..<limits.maxRounds {
            try Task.checkCancellation()
            try await deliverQueued()
            var items = try await store.items(of: conversationID)
            var request = makeRequest(items: items, tools: useTools ? await registry.specs() : [])

            if let window = modelConfig.contextWindow, let compactor, !compactionFailed,
               ContextEstimate.tokens(request) > Int(Double(window) * limits.compactionThreshold),
               let cut = Compactor.cut(in: items, budget: Int(Double(window) * limits.compactionKeepShare)) {
                emit(.compacting(conversationID: conversationID, true))
                do {
                    let item = try await compactor.compact(items, keepingFrom: cut, conversationID: conversationID,
                                                           turnID: turn.id)
                    emit(.itemAdded(item))
                    items = try await store.items(of: conversationID)
                    request = makeRequest(items: items, tools: request.tools)
                } catch is CancellationError {
                    emit(.compacting(conversationID: conversationID, false))
                    throw CancellationError()
                } catch {
                    // Carry on uncompacted; the provider may still cope.
                    compactionFailed = true
                }
                emit(.compacting(conversationID: conversationID, false))
            }

            var calls: [ToolCall] = []
            var stop: StopReason = .endTurn
            for try await event in provider.stream(request) {
                emit(.inference(conversationID: conversationID, event))
                switch event {
                case .itemCompleted(let payload):
                    try await append(payload)
                    if case .toolCall(let call) = payload { calls.append(call) }
                case .usage(let delta):
                    usage = usage + delta
                case .finished(let reason):
                    stop = reason
                default:
                    break
                }
            }

            if calls.isEmpty {
                // Messages that arrived during the answer keep the turn going.
                guard try await deliverQueued() else { return stop }
                continue
            }
            try await runCalls(calls, counts: &callCounts, interaction: interaction)
        }
        return .other("max_rounds")
    }

    /// Appends queued messages to the conversation. Returns whether there were any.
    @discardableResult
    private func deliverQueued() async throws -> Bool {
        let messages = await takeQueued()
        for text in messages {
            try await append(.message(Message(role: .user, text: text)))
        }
        return !messages.isEmpty
    }

    private func makeRequest(items: [Item], tools: [ToolSpec]) -> InferenceRequest {
        InferenceRequest(
            model: turn.model.model,
            instructions: instructions,
            items: Self.history(from: items),
            tools: tools,
            maxOutputTokens: modelConfig.maxOutputTokens,
            reasoningEffort: modelConfig.reasoningEffort)
    }

    /// Runs a round's calls. Consecutive calls to read-only tools that run
    /// without asking go concurrently; everything else (anything that may
    /// change something, or needs the user) runs alone, in order. Results
    /// are stored in call order either way, so the history doesn't depend on
    /// which call finished first.
    private func runCalls(_ calls: [ToolCall], counts: inout [String: Int], interaction: TurnInteraction) async throws {
        var index = 0
        while index < calls.count {
            try Task.checkCancellation()
            var batch: [(call: ToolCall, repeatCount: Int)] = []
            while index < calls.count, await runsInParallel(calls[index]) {
                batch.append((calls[index], Self.bump(&counts, calls[index])))
                index += 1
            }
            if batch.isEmpty {
                let call = calls[index]
                index += 1
                batch = [(call, Self.bump(&counts, call))]
            }

            let outputs: [ToolOutput]
            if batch.count == 1 {
                outputs = [await execute(batch[0].call, repeatCount: batch[0].repeatCount, interaction: interaction)]
            } else {
                outputs = await withTaskGroup(of: (Int, ToolOutput).self) { group in
                    for (position, entry) in batch.enumerated() {
                        group.addTask {
                            (position, await execute(entry.call, repeatCount: entry.repeatCount, interaction: interaction))
                        }
                    }
                    var results = [ToolOutput](repeating: ToolOutput(""), count: batch.count)
                    for await (position, output) in group { results[position] = output }
                    return results
                }
            }
            for (entry, output) in zip(batch, outputs) {
                try await append(.toolResult(ToolResult(callID: entry.call.id, output: output.text, isError: output.isError)))
                emit(.toolFinished(conversationID: conversationID, call: entry.call, output: output))
            }
        }
    }

    private func runsInParallel(_ call: ToolCall) async -> Bool {
        guard let tool = await registry.tool(named: call.name), tool.isReadOnly else { return false }
        return await registry.policy(for: tool) == .allow
    }

    private static func bump(_ counts: inout [String: Int], _ call: ToolCall) -> Int {
        let signature = call.name + "\u{0}" + call.arguments
        counts[signature, default: 0] += 1
        return counts[signature]!
    }

    private func execute(_ call: ToolCall, repeatCount: Int, interaction: TurnInteraction) async -> ToolOutput {
        guard let tool = await registry.tool(named: call.name) else {
            return .error("There is no tool named “\(call.name)”.")
        }
        if repeatCount > limits.maxIdenticalCalls {
            return .error("This exact call was already made \(repeatCount - 1) times in this turn. Try something different.")
        }
        do {
            switch await registry.policy(for: tool) {
            case .deny:
                return .error("The user's settings don't allow this tool.")
            case .ask:
                let approved = try await interaction.approve(ApprovalRequest(
                    conversationID: conversationID, callID: call.id, tool: call.name, arguments: call.arguments))
                if !approved { return .error("The user declined this call.") }
            case .allow:
                break
            }
            let context = ToolContext(conversationID: conversationID, turnID: turn.id, callID: call.id,
                                      folders: folders, store: store, interaction: interaction)
            let output = try await tool.run(arguments: Data(call.arguments.utf8), context: context)
            return Self.cap(output, at: limits.maxToolOutputCharacters)
        } catch is CancellationError {
            return .error("Cancelled.")
        } catch {
            return .error(error.localizedDescription)
        }
    }

    private func append(_ payload: Item.Payload) async throws {
        let item = Item(conversationID: conversationID, turnID: turn.id, payload: payload)
        try await store.append(item)
        emit(.itemAdded(item))
    }

    /// The items a request should carry: the latest summary, then every item
    /// after what it covers. A call left unanswered by an interrupted turn
    /// gets a placeholder result; providers reject histories with dangling
    /// calls.
    static func history(from items: [Item]) -> [Item.Payload] {
        var payloads = items.map(\.payload)
        if let last = items.lastIndex(where: { if case .compaction = $0.payload { true } else { false } }) {
            let start = Compactor.activeStart(in: items)
            let kept = items.indices[start...].compactMap { index -> Item.Payload? in
                switch items[index].payload {
                case .compaction:
                    return nil
                case .reasoning(var reasoning) where index < last:
                    // Its opaque state belongs to the history the summary
                    // replaced; providers that check it would refuse it.
                    reasoning.opaque = nil
                    reasoning.provider = nil
                    return .reasoning(reasoning)
                case let payload:
                    return payload
                }
            }
            payloads = [items[last].payload] + kept
        }
        let answered = Set(payloads.compactMap { if case .toolResult(let r) = $0 { r.callID } else { nil } })

        var result: [Item.Payload] = []
        for payload in payloads {
            result.append(payload)
            if case .toolCall(let call) = payload, !answered.contains(call.id) {
                result.append(.toolResult(ToolResult(callID: call.id, output: "Interrupted before completing.", isError: true)))
            }
        }
        return result
    }

    /// Calls made in `turnID` that have no result yet, in order.
    static func unansweredCalls(in items: [Item], turnID: UUID) -> [ToolCall] {
        let answered = Set(items.compactMap { if case .toolResult(let r) = $0.payload { r.callID } else { nil } })
        return items.compactMap { item in
            guard item.turnID == turnID, case .toolCall(let call) = item.payload, !answered.contains(call.id) else { return nil }
            return call
        }
    }

    static func cap(_ output: ToolOutput, at limit: Int) -> ToolOutput {
        guard output.text.count > limit else { return output }
        let kept = output.text.prefix(limit)
        return ToolOutput("\(kept)\n\n[Output truncated: \(output.text.count - limit) more characters.]",
                          isError: output.isError)
    }
}

/// The per-model settings a turn needs, resolved from `config.json`.
struct ModelConfigSnapshot: Sendable {
    var maxOutputTokens: Int?
    var reasoningEffort: String?
    var contextWindow: Int?
}

/// Marks the turn as awaiting input while a tool waits for the user, so a
/// relaunch knows to resume it.
struct TurnInteraction: UserInteraction {
    let base: any UserInteraction
    let store: Store
    let turnID: UUID

    func clarify(_ request: ClarifyRequest) async throws -> [String: String] {
        try await waiting { try await base.clarify(request) }
    }

    func approve(_ request: ApprovalRequest) async throws -> Bool {
        try await waiting { try await base.approve(request) }
    }

    private func waiting<T: Sendable>(_ ask: () async throws -> T) async throws -> T {
        try await store.setTurnStatus(turnID, .awaitingInput)
        let answer = try await ask()
        try await store.setTurnStatus(turnID, .running)
        return answer
    }
}
