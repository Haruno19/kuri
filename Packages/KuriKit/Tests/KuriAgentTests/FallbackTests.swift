import Foundation
import KuriConfig
import KuriCore
import KuriInference
import KuriStore
import KuriTools
import Synchronization
import Testing
@testable import KuriAgent

/// Streams `before`, then fails, counting its requests.
private final class FailingProvider: InferenceProvider {
    let before: [InferenceEvent]
    let requests = Mutex(0)
    init(before: [InferenceEvent] = []) { self.before = before }

    func stream(_ request: InferenceRequest) -> AsyncThrowingStream<InferenceEvent, any Error> {
        requests.withLock { $0 += 1 }
        let before = before
        return AsyncThrowingStream { continuation in
            for event in before { continuation.yield(event) }
            continuation.finish(throwing: KuriError.http(status: 503, body: "Overloaded"))
        }
    }
}

private final class Events: Sendable {
    let list = Mutex<[EngineEvent]>([])
    var fallbacks: [(from: ModelRef, to: ModelRef, reason: String)] {
        list.withLock { $0 }.compactMap {
            if case .modelFallback(_, let from, let to, let reason) = $0 { (from, to, reason) } else { nil }
        }
    }
}

@Suite struct FallbackTests {
    private func runner(primary: any InferenceProvider, fallback: ScriptedProvider, events: Events)
        async throws -> (TurnRunner, Store, UUID)
    {
        let store = try Store(url: nil)
        let conversation = Conversation(model: ModelRef(provider: "a", model: "big"))
        try await store.createConversation(conversation)
        try await store.append(Item(conversationID: conversation.id, payload: .message(Message(role: .user, text: "Plan it"))))
        let turn = try await store.beginTurn(conversationID: conversation.id, model: ModelRef(provider: "a", model: "big"))
        let runner = TurnRunner(
            conversationID: conversation.id, turn: turn, provider: primary, modelConfig: ModelConfigSnapshot(),
            instructions: "test", folders: [], registry: ToolRegistry(BuiltInTools.all), store: store,
            interaction: Answering(), limits: TurnLimits(), compactor: nil,
            fallbacks: [ModelChoice(model: ModelRef(provider: "b", model: "small"), provider: fallback,
                                    modelConfig: ModelConfigSnapshot(maxOutputTokens: 100), instructions: "fallback",
                                    useTools: true)],
            emit: { event in events.list.withLock { $0.append(event) } })
        return (runner, store, conversation.id)
    }

    @Test func aFailedRequestGoesToTheFallbackForTheRestOfTheTurn() async throws {
        let primary = FailingProvider()
        let fallback = ScriptedProvider([
            [.itemCompleted(.toolCall(ToolCall(id: "t", name: "tasklist", arguments: #"{"tasks":[]}"#))), .finished(.toolUse)],
            [.itemCompleted(.message(Message(role: .assistant, text: "Done."))), .finished(.endTurn)],
        ])
        let events = Events()
        let (runner, _, _) = try await runner(primary: primary, fallback: fallback, events: events)

        #expect(await runner.run() == .completed(.endTurn))
        // One failed request; both rounds then ran on the fallback, with its own settings.
        #expect(primary.requests.withLock { $0 } == 1)
        let requests = fallback.requests.withLock { $0 }
        #expect(requests.map(\.model) == ["small", "small"])
        #expect(requests.allSatisfy { $0.instructions == "fallback" && $0.maxOutputTokens == 100 })
        let switched = try #require(events.fallbacks.first)
        #expect(switched.from == ModelRef(provider: "a", model: "big"))
        #expect(switched.to == ModelRef(provider: "b", model: "small"))
        #expect(switched.reason.contains("503"))
    }

    @Test func noFallbackOnceSomethingWasStored() async throws {
        // Retrying would store the reasoning twice; the turn fails instead.
        let primary = FailingProvider(before: [.itemCompleted(.reasoning(Reasoning(text: "Thinking")))])
        let fallback = ScriptedProvider([[.itemCompleted(.message(Message(role: .assistant, text: "Hi"))), .finished(.endTurn)]])
        let events = Events()
        let (runner, store, conversationID) = try await runner(primary: primary, fallback: fallback, events: events)

        guard case .failed = await runner.run() else {
            Issue.record("the turn should fail")
            return
        }
        #expect(fallback.requests.withLock { $0.count } == 0)
        #expect(events.fallbacks.isEmpty)
        #expect(try await store.items(of: conversationID).map(\.payload.kind) == ["message", "reasoning"])
    }
}

/// Answers every request to `down.test` with an HTTP error.
final class DownProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "down.test" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let response = HTTPURLResponse(url: request.url!, statusCode: 500, httpVersion: "HTTP/1.1", headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(#"{"error":{"message":"Server on fire"}}"#.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

extension EngineTests {
    @Test func configuredFallbacksTakeOverAFailingModel() async throws {
        StubResponsesProtocol.requestBodies.withLock { $0 = [] }
        StubResponsesProtocol.bodies.withLock {
            $0 = [StubResponsesProtocol.sse([
                #"{"type":"response.output_item.done","item":{"type":"message","role":"assistant","content":[{"type":"output_text","text":"Hello from the fallback."}]}}"#,
                #"{"type":"response.completed","response":{}}"#,
            ])]
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [DownProtocol.self, StubResponsesProtocol.self]
        let root = FileManager.default.temporaryDirectory.appending(path: "kuri-fallback-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let home = KuriHome(root: root)
        try home.prepare()
        let engine = Engine(
            home: home, store: try Store(url: home.database),
            config: Config(
                defaultModel: ModelRef("down/m"),
                providers: [
                    "down": ProviderConfig(format: .openResponses, baseURL: URL(string: "http://down.test/v1"),
                                           models: [ModelConfig(id: "m", fallbacks: [ModelRef("nowhere/x")!, ModelRef("stub/m")!])]),
                    "stub": ProviderConfig(format: .openResponses, baseURL: URL(string: "http://stub.test/v1")),
                ],
                generateTitles: false),
            mcpConfig: MCPConfig(), factory: ProviderFactory(session: URLSession(configuration: configuration)))
        await engine.start()
        defer { Task { await engine.shutdown() } }

        let events = engine.events()
        let conversation = try await engine.newConversation()
        try await engine.send("Hi", to: conversation.id)
        var fallback: (ModelRef, ModelRef, String)?
        var outcome: TurnOutcome?
        for await event in events {
            if case .modelFallback(_, let from, let to, let reason) = event { fallback = (from, to, reason) }
            if case .turnFinished(_, _, let finished) = event { outcome = finished; break }
        }
        #expect(outcome == .completed(.endTurn))
        // The unknown provider is skipped; the server's own message is the reason.
        #expect(fallback?.0 == ModelRef("down/m"))
        #expect(fallback?.1 == ModelRef("stub/m"))
        #expect(fallback?.2.contains("Server on fire") == true)
        let reply = try await engine.store.items(of: conversation.id).last
        #expect(reply.map { if case .message(let m) = $0.payload { m.text } else { "" } } == "Hello from the fallback.")
    }
}
