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
    let emit: @Sendable (EngineEvent) -> Void

    func run() async -> TurnOutcome {
        var usage = Usage()
        var stop: StopReason = .endTurn
        let outcome: TurnOutcome
        do {
            stop = try await loop(usage: &usage)
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

    private func loop(usage: inout Usage) async throws -> StopReason {
        var callCounts: [String: Int] = [:]

        for _ in 0..<limits.maxRounds {
            try Task.checkCancellation()
            let request = InferenceRequest(
                model: turn.model.model,
                instructions: instructions,
                items: Self.history(from: try await store.items(of: conversationID)),
                tools: await registry.specs(),
                maxOutputTokens: modelConfig.maxOutputTokens,
                reasoningEffort: modelConfig.reasoningEffort)

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

            guard !calls.isEmpty else { return stop }

            // Sequential for now. Read-only tools (`Tool.isReadOnly`) could
            // run in parallel; worth it once file tools and MCP land.
            for call in calls {
                try Task.checkCancellation()
                let signature = call.name + "\u{0}" + call.arguments
                callCounts[signature, default: 0] += 1
                let output = await execute(call, repeatCount: callCounts[signature]!)
                try await append(.toolResult(ToolResult(callID: call.id, output: output.text, isError: output.isError)))
            }
        }
        return .other("max_rounds")
    }

    private func execute(_ call: ToolCall, repeatCount: Int) async -> ToolOutput {
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

    /// The items a request should carry: everything since the last
    /// compaction (the compaction included), with a placeholder result for
    /// any call left unanswered by an interrupted turn — providers reject
    /// histories with dangling calls.
    static func history(from items: [Item]) -> [Item.Payload] {
        let start = items.lastIndex { if case .compaction = $0.payload { true } else { false } } ?? items.startIndex
        let payloads = items[start...].map(\.payload)
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
}
