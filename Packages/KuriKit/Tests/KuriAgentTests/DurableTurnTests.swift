import Foundation
import KuriConfig
import KuriCore
import KuriInference
import KuriStore
import KuriTools
import Testing
@testable import KuriAgent

private func message(_ role: Role, _ text: String, in conversation: UUID, turn: UUID? = nil) -> Item {
    Item(conversationID: conversation, turnID: turn, payload: .message(Message(role: role, text: text)))
}

@Suite struct CompactionTests {
    let conversation = UUID()

    @Test func historyStartsWithTheSummaryAndKeepsWhatItDoesntCover() {
        let u1 = message(.user, "one", in: conversation), a1 = message(.assistant, "uno", in: conversation)
        let u2 = message(.user, "two", in: conversation), a2 = message(.assistant, "dos", in: conversation)
        let summary = Item(conversationID: conversation, payload: .compaction(Compaction(summary: "S", throughItemID: a1.id)))
        let u3 = message(.user, "three", in: conversation)

        let history = TurnRunner.history(from: [u1, a1, u2, a2, summary, u3])
        #expect(history == [summary.payload, u2.payload, a2.payload, u3.payload])
        #expect(Compactor.activeStart(in: [u1, a1, u2, a2, summary, u3]) == 2)
    }

    @Test func cutKeepsTheLatestExchangeAndNeverSplitsACall() {
        let items = [
            message(.user, String(repeating: "a", count: 400), in: conversation),
            message(.assistant, String(repeating: "b", count: 400), in: conversation),
            message(.user, "now", in: conversation),
            Item(conversationID: conversation, payload: .toolCall(ToolCall(id: "c", name: "t", arguments: String(repeating: "x", count: 800)))),
            Item(conversationID: conversation, payload: .toolResult(ToolResult(callID: "c", output: String(repeating: "y", count: 800)))),
            message(.assistant, "done", in: conversation),
        ]
        #expect(Compactor.cut(in: items, budget: .max) == 2)
        // Too little room for the whole exchange: keep its tail, from an item that isn't a result.
        let cut = Compactor.cut(in: items, budget: 20)
        #expect(cut == 5)
        // A single exchange has nothing before it to summarize.
        #expect(Compactor.cut(in: Array(items[2...]), budget: .max) == nil)
    }

    @Test func compactsAutomaticallyWhenTheContextFillsUp() async throws {
        let store = try Store(url: nil)
        let conversation = Conversation(model: ModelRef("test/m"))
        try await store.createConversation(conversation)
        let u1 = message(.user, String(repeating: "Tell me about chestnuts. ", count: 120), in: conversation.id)
        let a1 = message(.assistant, String(repeating: "Chestnuts are nuts. ", count: 120), in: conversation.id)
        for item in [u1, a1, message(.user, "And their Japanese name?", in: conversation.id)] {
            try await store.append(item)
        }
        let provider = ScriptedProvider([
            [.itemCompleted(.message(Message(role: .assistant, text: "The user asked about chestnuts."))), .finished(.endTurn)],
            [.itemCompleted(.message(Message(role: .assistant, text: "Kuri, 栗."))), .finished(.endTurn)],
        ])
        let turn = try await store.beginTurn(conversationID: conversation.id, model: ModelRef(provider: "test", model: "m"))
        let runner = TurnRunner(
            conversationID: conversation.id, turn: turn, provider: provider,
            modelConfig: ModelConfigSnapshot(contextWindow: 2_000), instructions: "test", folders: [],
            registry: ToolRegistry(BuiltInTools.all), store: store, interaction: Answering(), limits: TurnLimits(),
            compactor: Compactor(provider: provider, model: "m", store: store), emit: { _ in })

        #expect(await runner.run() == .completed(.endTurn))

        let requests = provider.requests.withLock { $0 }
        #expect(requests.count == 2)
        #expect(requests[0].instructions == Compactor.instructions)
        guard case .compaction(let compaction) = requests[1].items.first else {
            Issue.record("the answer's request should start with the summary")
            return
        }
        #expect(compaction.summary == "The user asked about chestnuts.")
        #expect(compaction.throughItemID == a1.id)
        #expect(requests[1].items.count == 2)  // summary + the latest question
    }

    @Test func resumingAsksTheUnansweredQuestionAgain() async throws {
        let store = try Store(url: nil)
        let conversation = Conversation(model: ModelRef("test/m"))
        try await store.createConversation(conversation)
        let turn = try await store.beginTurn(conversationID: conversation.id, model: ModelRef(provider: "test", model: "m"))
        try await store.append(message(.user, "Plan a trip", in: conversation.id, turn: turn.id))
        try await store.append(Item(conversationID: conversation.id, turnID: turn.id, payload: .toolCall(ToolCall(
            id: "q1", name: "clarify", arguments: #"{"questions":[{"id":"city","question":"Which city?"}]}"#))))
        try await store.setTurnStatus(turn.id, .awaitingInput)

        let provider = ScriptedProvider([[.itemCompleted(.message(Message(role: .assistant, text: "Blue city it is."))), .finished(.endTurn)]])
        let runner = TurnRunner(
            conversationID: conversation.id, turn: turn, provider: provider, modelConfig: ModelConfigSnapshot(),
            instructions: "test", folders: [], registry: ToolRegistry(BuiltInTools.all), store: store,
            interaction: Answering(), limits: TurnLimits(), compactor: nil, emit: { _ in })

        #expect(await runner.run(resuming: true) == .completed(.endTurn))
        let results = try await store.items(of: conversation.id).compactMap {
            if case .toolResult(let result) = $0.payload { result } else { nil }
        }
        #expect(results.map(\.callID) == ["q1"])
        #expect(results.first?.output.contains("blue") == true)
        #expect(try await store.turns(of: conversation.id).first?.status == .completed)
    }
}

// Engine-level flows, in the serialized EngineTests suite (they share the HTTP stub).
extension EngineTests {
    private func makeEngine(tools: [String: ToolPolicy]? = nil) throws -> (Engine, KuriHome) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubResponsesProtocol.self]
        let root = FileManager.default.temporaryDirectory.appending(path: "kuri-durable-\(UUID().uuidString)")
        let home = KuriHome(root: root)
        try home.prepare()
        let engine = Engine(
            home: home, store: try Store(url: home.database),
            config: Config(defaultModel: ModelRef("stub/m"),
                           providers: ["stub": ProviderConfig(format: .openResponses, baseURL: URL(string: "http://stub.test/v1"))],
                           tools: tools),
            mcpConfig: MCPConfig(), factory: ProviderFactory(session: URLSession(configuration: configuration)))
        return (engine, home)
    }

    private static let finalAnswer = StubResponsesProtocol.sse([
        #"{"type":"response.output_item.done","item":{"type":"message","role":"assistant","content":[{"type":"output_text","text":"Done."}]}}"#,
        #"{"type":"response.completed","response":{}}"#,
    ])

    @Test func resumesAPendingApprovalAfterARelaunch() async throws {
        StubResponsesProtocol.requestBodies.withLock { $0 = [] }
        StubResponsesProtocol.bodies.withLock { $0 = [Self.finalAnswer] }
        let (engine, home) = try makeEngine(tools: ["tasklist": .ask])
        defer { try? FileManager.default.removeItem(at: home.root) }
        await engine.start()
        defer { Task { await engine.shutdown() } }

        // What a previous launch left behind: a turn waiting on an approval.
        let conversation = try await engine.newConversation()
        let turn = try await engine.store.beginTurn(conversationID: conversation.id, model: ModelRef(provider: "stub", model: "m"))
        try await engine.store.append(message(.user, "Plan it", in: conversation.id, turn: turn.id))
        try await engine.store.append(Item(conversationID: conversation.id, turnID: turn.id, payload: .toolCall(ToolCall(
            id: "t1", name: "tasklist", arguments: #"{"tasks":[{"content":"Pack","status":"pending"}]}"#))))
        try await engine.store.setTurnStatus(turn.id, .awaitingInput)

        let events = engine.events()
        await engine.resumePendingTurns()

        var outcome: TurnOutcome?
        for await event in events {
            if case .inputRequested(let request) = event, case .approval(let approval) = request.kind {
                #expect(approval.callID == "t1")
                #expect(try await engine.store.turns(of: conversation.id).first?.status == .awaitingInput)
                await engine.respond(to: request.id, with: .approved(true))
            }
            if case .turnFinished(_, _, let finished) = event {
                outcome = finished
                break
            }
        }
        #expect(outcome == .completed(.endTurn))
        let kinds = try await engine.store.items(of: conversation.id).map(\.payload.kind)
        #expect(kinds == ["message", "toolCall", "toolResult", "message"])
    }

    @Test func continuesAnInterruptedTurn() async throws {
        StubResponsesProtocol.requestBodies.withLock { $0 = [] }
        StubResponsesProtocol.bodies.withLock { $0 = [Self.finalAnswer] }
        let (engine, home) = try makeEngine()
        defer { try? FileManager.default.removeItem(at: home.root) }

        let conversation = try await engine.newConversation()
        let turn = try await engine.store.beginTurn(conversationID: conversation.id, model: ModelRef(provider: "stub", model: "m"))
        try await engine.store.append(message(.user, "Go", in: conversation.id, turn: turn.id))
        try await engine.store.append(Item(conversationID: conversation.id, turnID: turn.id,
                                           payload: .toolCall(ToolCall(id: "x", name: "memory", arguments: "{}"))))
        try await engine.store.recoverInterruptedTurns()

        let events = engine.events()
        try await engine.continueConversation(conversation.id)
        for await event in events {
            if case .turnFinished(_, _, let finished) = event {
                #expect(finished == .completed(.endTurn))
                break
            }
        }
        let body = try JSONDecoder().decode(JSONValue.self, from: try #require(StubResponsesProtocol.requestBodies.withLock { $0.last }))
        guard case .array(let input) = body["input"] else {
            Issue.record("no input")
            return
        }
        #expect(input.last?["type"] == "function_call_output")
        #expect(input.last?["output"] == "Interrupted before completing.")
    }

    @Test func compactsOnDemand() async throws {
        StubResponsesProtocol.requestBodies.withLock { $0 = [] }
        StubResponsesProtocol.bodies.withLock {
            $0 = [StubResponsesProtocol.sse([
                #"{"type":"response.output_item.done","item":{"type":"message","role":"assistant","content":[{"type":"output_text","text":"Summary."}]}}"#,
                #"{"type":"response.completed","response":{}}"#,
            ])]
        }
        let (engine, home) = try makeEngine()
        defer { try? FileManager.default.removeItem(at: home.root) }
        let conversation = try await engine.newConversation()
        let a1 = message(.assistant, "uno", in: conversation.id)
        for item in [message(.user, "one", in: conversation.id), a1,
                     message(.user, "two", in: conversation.id), message(.assistant, "dos", in: conversation.id)] {
            try await engine.store.append(item)
        }
        let before = try await engine.contextUsage(conversation.id)

        try await engine.compact(conversation.id)

        guard case .compaction(let compaction) = try await engine.store.items(of: conversation.id).last?.payload else {
            Issue.record("expected a compaction item")
            return
        }
        #expect(compaction.summary == "Summary.")
        #expect(compaction.throughItemID == a1.id)
        #expect(before.window == nil)
        #expect(await engine.isRunning(conversation.id) == false)
    }
}
