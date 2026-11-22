import Foundation
import KuriCore
import KuriInference
import KuriStore
import KuriTools
import Synchronization
import Testing
@testable import KuriAgent

/// Replays one scripted response per request and records the requests.
final class ScriptedProvider: InferenceProvider {
    private let script: Mutex<[[InferenceEvent]]>
    let requests = Mutex<[InferenceRequest]>([])

    init(_ script: [[InferenceEvent]]) {
        self.script = Mutex(script)
    }

    func stream(_ request: InferenceRequest) -> AsyncThrowingStream<InferenceEvent, any Error> {
        requests.withLock { $0.append(request) }
        let events = script.withLock { $0.isEmpty ? [.finished(.endTurn)] : $0.removeFirst() }
        return AsyncThrowingStream { continuation in
            for event in events { continuation.yield(event) }
            continuation.finish()
        }
    }
}

struct Answering: UserInteraction {
    func clarify(_ request: ClarifyRequest) async throws -> [String: String] {
        Dictionary(uniqueKeysWithValues: request.questions.map { ($0.id, "blue") })
    }
    func approve(_ request: ApprovalRequest) async throws -> Bool { true }
}

@Suite struct TurnRunnerTests {
    let model = ModelRef(provider: "test", model: "m")

    private func runner(store: Store, conversation: Conversation, provider: ScriptedProvider,
                        limits: TurnLimits = TurnLimits()) async throws -> TurnRunner {
        let turn = try await store.beginTurn(conversationID: conversation.id, model: model)
        return TurnRunner(
            conversationID: conversation.id, turn: turn, provider: provider,
            modelConfig: ModelConfigSnapshot(), instructions: "test", folders: [],
            registry: ToolRegistry(BuiltInTools.all), store: store, interaction: Answering(),
            limits: limits, compactor: nil, emit: { _ in })
    }

    @Test func runsToolsUntilTheModelAnswers() async throws {
        let store = try Store(url: nil)
        let conversation = Conversation(model: model)
        try await store.createConversation(conversation)
        try await store.append(Item(conversationID: conversation.id, payload: .message(Message(role: .user, text: "Pick a color"))))

        let clarify = ToolCall(id: "c1", name: "clarify",
                               arguments: #"{"questions":[{"id":"color","question":"Which color?"}]}"#)
        let provider = ScriptedProvider([
            [.itemCompleted(.toolCall(clarify)), .usage(Usage(inputTokens: 10, outputTokens: 5)), .finished(.toolUse)],
            [.itemCompleted(.message(Message(role: .assistant, text: "Blue it is."))),
             .usage(Usage(inputTokens: 20, outputTokens: 3)), .finished(.endTurn)],
        ])

        let outcome = try await runner(store: store, conversation: conversation, provider: provider).run()
        #expect(outcome == .completed(.endTurn))

        let kinds = try await store.items(of: conversation.id).map(\.payload.kind)
        #expect(kinds == ["message", "toolCall", "toolResult", "message"])

        // The second request carried the tool result back to the model.
        let second = try #require(provider.requests.withLock { $0.last })
        guard case .toolResult(let result) = second.items.last else {
            Issue.record("expected a tool result last")
            return
        }
        #expect(result.output.contains("blue"))

        let turn = try #require(try await store.turns(of: conversation.id).first)
        #expect(turn.status == .completed)
        #expect(turn.usage.inputTokens == 30)
    }

    @Test func stopsIdenticalRepeatedCalls() async throws {
        let store = try Store(url: nil)
        let conversation = Conversation(model: model)
        try await store.createConversation(conversation)

        let call = { (id: String) in
            [InferenceEvent.itemCompleted(.toolCall(ToolCall(id: id, name: "tasklist", arguments: #"{"tasks":[]}"#))),
             .finished(.toolUse)]
        }
        let provider = ScriptedProvider([call("1"), call("2"), call("3")])
        var limits = TurnLimits()
        limits.maxIdenticalCalls = 2

        _ = try await runner(store: store, conversation: conversation, provider: provider, limits: limits).run()
        let results = try await store.items(of: conversation.id).compactMap {
            if case .toolResult(let result) = $0.payload { result } else { nil }
        }
        #expect(results.map(\.isError) == [false, false, true])
    }

    @Test func historyStartsAtCompactionAndClosesDanglingCalls() {
        let id = UUID()
        func item(_ payload: Item.Payload) -> Item { Item(conversationID: id, payload: payload) }
        let history = TurnRunner.history(from: [
            item(.message(Message(role: .user, text: "old"))),
            item(.compaction(Compaction(summary: "sum"))),
            item(.toolCall(ToolCall(id: "x", name: "clarify", arguments: "{}"))),
            item(.message(Message(role: .user, text: "new"))),
        ])
        #expect(history.map(\.kind) == ["compaction", "toolCall", "toolResult", "message"])
    }

    @Test func capsLongToolOutput() {
        let capped = TurnRunner.cap(ToolOutput(String(repeating: "a", count: 50)), at: 10)
        #expect(capped.text.hasPrefix("aaaaaaaaaa\n\n[Output truncated: 40 more"))
    }
}
