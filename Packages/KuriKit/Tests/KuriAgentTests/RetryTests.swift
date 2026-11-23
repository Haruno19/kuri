import Foundation
import KuriConfig
import KuriCore
import KuriInference
import KuriStore
import Testing
@testable import KuriAgent

extension EngineTests {
    @Test func retryReplacesTheLastAnswer() async throws {
        StubResponsesProtocol.requestBodies.withLock { $0 = [] }
        StubResponsesProtocol.bodies.withLock {
            $0 = ["First answer.", "Second answer."].map { text in
                StubResponsesProtocol.sse([
                    #"{"type":"response.output_item.done","item":{"type":"message","role":"assistant","content":[{"type":"output_text","text":"\#(text)"}]}}"#,
                    #"{"type":"response.completed","response":{}}"#,
                ])
            }
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubResponsesProtocol.self]
        let root = FileManager.default.temporaryDirectory.appending(path: "kuri-retry-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let home = KuriHome(root: root)
        try home.prepare()
        let engine = Engine(
            home: home, store: try Store(url: home.database),
            config: Config(defaultModel: ModelRef("stub/m"),
                           providers: ["stub": ProviderConfig(format: .openResponses, baseURL: URL(string: "http://stub.test/v1"))],
                           generateTitles: false),
            mcpConfig: MCPConfig(), factory: ProviderFactory(session: URLSession(configuration: configuration)))
        await engine.start()
        defer { Task { await engine.shutdown() } }

        let events = engine.events()
        let conversation = try await engine.newConversation()
        try await engine.send("Hi", to: conversation.id)
        var removed: [UUID] = []
        var finished = 0
        for await event in events {
            if case .itemsRemoved(_, let ids) = event { removed = ids }
            if case .turnFinished = event {
                finished += 1
                if finished == 1 { try await engine.retry(conversation.id) } else { break }
            }
        }

        let items = try await engine.store.items(of: conversation.id)
        let texts = items.compactMap { item -> String? in if case .message(let m) = item.payload { m.text } else { nil } }
        #expect(texts == ["Hi", "Second answer."])
        #expect(removed.count == 1)
        #expect(!items.map { $0.id }.contains(removed.first ?? UUID()))
        // Two turns on record; the retry is the second.
        #expect(try await engine.store.turns(of: conversation.id).count == 2)
    }
}
