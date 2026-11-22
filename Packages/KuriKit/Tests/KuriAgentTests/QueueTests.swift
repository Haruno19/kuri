import Foundation
import KuriConfig
import KuriCore
import KuriInference
import KuriStore
import KuriTools
import Synchronization
import Testing
@testable import KuriAgent

/// Hands out queued messages on a schedule: the n-th call gets `script[n]`.
private final class QueueScript: Sendable {
    private let script: Mutex<[[String]]>
    init(_ script: [[String]]) { self.script = Mutex(script) }
    func take() -> [String] { script.withLock { $0.isEmpty ? [] : $0.removeFirst() } }
}

@Suite struct QueueTests {
    private func setUp() async throws -> (Store, Conversation, Turn) {
        let store = try Store(url: nil)
        let conversation = Conversation(model: ModelRef(provider: "test", model: "m"))
        try await store.createConversation(conversation)
        try await store.append(Item(conversationID: conversation.id, payload: .message(Message(role: .user, text: "Plan it"))))
        let turn = try await store.beginTurn(conversationID: conversation.id, model: ModelRef(provider: "test", model: "m"))
        return (store, conversation, turn)
    }

    private func runner(_ store: Store, _ conversation: Conversation, _ turn: Turn, provider: ScriptedProvider,
                        queue: QueueScript) -> TurnRunner {
        TurnRunner(
            conversationID: conversation.id, turn: turn, provider: provider, modelConfig: ModelConfigSnapshot(),
            instructions: "test", folders: [], registry: ToolRegistry(BuiltInTools.all), store: store,
            interaction: Answering(), limits: TurnLimits(), compactor: nil, takeQueued: { queue.take() }, emit: { _ in })
    }

    @Test func queuedMessagesJoinAfterAToolRound() async throws {
        let (store, conversation, turn) = try await setUp()
        let provider = ScriptedProvider([
            [.itemCompleted(.toolCall(ToolCall(id: "t", name: "tasklist", arguments: #"{"tasks":[]}"#))), .finished(.toolUse)],
            [.itemCompleted(.message(Message(role: .assistant, text: "Done, and noted."))), .finished(.endTurn)],
        ])
        // Nothing before the first request; one message before the second.
        let queue = QueueScript([[], ["Also add a deadline"]])
        #expect(await runner(store, conversation, turn, provider: provider, queue: queue).run() == .completed(.endTurn))

        let second = try #require(provider.requests.withLock { $0.last })
        guard case .message(let message) = second.items.last else {
            Issue.record("the queued message should be the latest item")
            return
        }
        #expect(message.text == "Also add a deadline")
        #expect(second.items.map(\.kind) == ["message", "toolCall", "toolResult", "message"])
    }

    @Test func aMessageArrivingDuringTheAnswerKeepsTheTurnGoing() async throws {
        let (store, conversation, turn) = try await setUp()
        let provider = ScriptedProvider([
            [.itemCompleted(.message(Message(role: .assistant, text: "Here's the plan."))), .finished(.endTurn)],
            [.itemCompleted(.message(Message(role: .assistant, text: "Shorter, then."))), .finished(.endTurn)],
        ])
        // Before round 1: nothing. When the answer ends: a message. Then nothing.
        let queue = QueueScript([[], ["Make it shorter"], []])
        #expect(await runner(store, conversation, turn, provider: provider, queue: queue).run() == .completed(.endTurn))

        #expect(provider.requests.withLock { $0.count } == 2)
        let texts = try await store.items(of: conversation.id).compactMap { item -> String? in
            if case .message(let m) = item.payload { "\(m.role.rawValue): \(m.text)" } else { nil }
        }
        #expect(texts == ["user: Plan it", "assistant: Here's the plan.", "user: Make it shorter", "assistant: Shorter, then."])
    }
}

extension EngineTests {
    @Test func sendingWhileBusyQueuesTheMessage() async throws {
        StubResponsesProtocol.requestBodies.withLock { $0 = [] }
        StubResponsesProtocol.bodies.withLock {
            $0 = [
                StubResponsesProtocol.sse([
                    #"{"type":"response.output_item.done","item":{"type":"function_call","id":"f","call_id":"t1","name":"tasklist","arguments":"{\"tasks\":[]}"}}"#,
                    #"{"type":"response.completed","response":{}}"#,
                ]),
                StubResponsesProtocol.sse([
                    #"{"type":"response.output_item.done","item":{"type":"message","role":"assistant","content":[{"type":"output_text","text":"Both done."}]}}"#,
                    #"{"type":"response.completed","response":{}}"#,
                ]),
            ]
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubResponsesProtocol.self]
        let root = FileManager.default.temporaryDirectory.appending(path: "kuri-queue-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let home = KuriHome(root: root)
        try home.prepare()
        let engine = Engine(
            home: home, store: try Store(url: home.database),
            config: Config(defaultModel: ModelRef("stub/m"),
                           providers: ["stub": ProviderConfig(format: .openResponses, baseURL: URL(string: "http://stub.test/v1"))],
                           tools: ["tasklist": .ask]),
            mcpConfig: MCPConfig(), factory: ProviderFactory(session: URLSession(configuration: configuration)))
        await engine.start()
        defer { Task { await engine.shutdown() } }

        let events = engine.events()
        let conversation = try await engine.newConversation()
        try await engine.send("First", to: conversation.id)

        var queuedSeen: [[String]] = []
        var outcome: TurnOutcome?
        for await event in events {
            switch event {
            case .inputRequested(let request):
                // The turn is busy waiting on the approval: this one queues.
                try await engine.send("Second", to: conversation.id)
                await engine.respond(to: request.id, with: .approved(true))
            case .queueChanged(_, let queue):
                queuedSeen.append(queue.map(\.text))
            case .turnFinished(_, _, let finished):
                outcome = finished
            default:
                break
            }
            if outcome != nil { break }
        }
        #expect(outcome == .completed(.endTurn))
        #expect(queuedSeen == [["Second"], []])
        let texts = try await engine.store.items(of: conversation.id).compactMap { item -> String? in
            if case .message(let m) = item.payload { m.text } else { nil }
        }
        #expect(texts == ["First", "Second", "Both done."])
        #expect(try await engine.store.turns(of: conversation.id).count == 1)  // joined the same turn
    }
}

@Suite struct ToolSupportTests {
    @Test func modelsWithoutToolsGetNone() async throws {
        let store = try Store(url: nil)
        let conversation = Conversation(model: ModelRef(provider: "test", model: "m"))
        try await store.createConversation(conversation)
        try await store.append(Item(conversationID: conversation.id, payload: .message(Message(role: .user, text: "Hi"))))
        let turn = try await store.beginTurn(conversationID: conversation.id, model: ModelRef(provider: "test", model: "m"))
        let provider = ScriptedProvider([[.itemCompleted(.message(Message(role: .assistant, text: "Hello"))), .finished(.endTurn)]])
        let runner = TurnRunner(
            conversationID: conversation.id, turn: turn, provider: provider, modelConfig: ModelConfigSnapshot(),
            instructions: "test", folders: [], registry: ToolRegistry(BuiltInTools.all), store: store,
            interaction: Answering(), limits: TurnLimits(), compactor: nil, useTools: false, emit: { _ in })
        _ = await runner.run()
        #expect(provider.requests.withLock { $0.first?.tools.isEmpty } == true)
    }
}

