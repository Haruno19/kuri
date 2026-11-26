import Foundation
import KuriConfig
import KuriCore
import KuriInference
import KuriStore
import Testing
@testable import KuriAgent

@Suite struct TitleCleaningTests {
    @Test(arguments: [
        ("Chestnuts in Japan", "Chestnuts in Japan"),
        ("\"Chestnuts in Japan.\"", "Chestnuts in Japan"),
        ("Title: **Chestnuts in Japan**", "Chestnuts in Japan"),
        ("Chestnuts in Japan\nThis conversation is about…", "Chestnuts in Japan"),
        ("  ", nil),
    ] as [(String, String?)])
    func cleansWhatModelsReturn(raw: String, expected: String?) {
        #expect(TitleGenerator.clean(raw) == expected)
    }

    @Test func longTitlesAreCut() {
        let title = TitleGenerator.clean(String(repeating: "word ", count: 30))
        #expect(title?.count == TitleGenerator.maxCharacters)
        #expect(title?.hasSuffix("…") == true)
    }
}

extension EngineTests {
    private func titleEngine(generateTitles: Bool?, titles: Bool = true) throws -> (Engine, KuriHome) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubResponsesProtocol.self]
        let home = KuriHome(root: FileManager.default.temporaryDirectory.appending(path: "kuri-title-\(UUID().uuidString)"))
        try home.prepare()
        let engine = Engine(
            home: home, store: try Store(url: home.database),
            config: Config(defaultModel: ModelRef("stub/m"),
                           providers: ["stub": ProviderConfig(format: .openResponses, baseURL: URL(string: "http://stub.test/v1"))],
                           generateTitles: generateTitles),
            mcpConfig: MCPConfig(), factory: ProviderFactory(session: URLSession(configuration: configuration)),
            titles: titles)
        return (engine, home)
    }

    private static func answer(_ text: String) -> String {
        StubResponsesProtocol.sse([
            #"{"type":"response.output_item.done","item":{"type":"message","role":"assistant","content":[{"type":"output_text","text":"\#(text)"}]}}"#,
            #"{"type":"response.completed","response":{}}"#,
        ])
    }

    @Test func titlesTheConversationAfterItsFirstTurn() async throws {
        StubResponsesProtocol.requestBodies.withLock { $0 = [] }
        StubResponsesProtocol.bodies.withLock { $0 = [Self.answer("Kuri means chestnut."), Self.answer("\\\"Chestnuts in Japanese.\\\"")] }
        let (engine, home) = try titleEngine(generateTitles: nil)
        defer { try? FileManager.default.removeItem(at: home.root) }
        let events = engine.events()
        let conversation = try await engine.newConversation()
        try await engine.send("what does kuri mean in japanese, and how do you write it?", to: conversation.id)

        var title: String?
        for await event in events {
            if case .conversationUpdated(let updated) = event, updated.id == conversation.id,
               updated.title == "Chestnuts in Japanese" {
                title = updated.title
                break
            }
        }
        #expect(title == "Chestnuts in Japanese")
        let body = try JSONDecoder().decode(JSONValue.self, from: try #require(StubResponsesProtocol.requestBodies.withLock { $0.last }))
        #expect(body["instructions"]?.stringValue == TitleGenerator.instructions)
    }

    @Test func noTitleWhenTurnedOff() async throws {
        StubResponsesProtocol.requestBodies.withLock { $0 = [] }
        StubResponsesProtocol.bodies.withLock { $0 = [Self.answer("Hello."), Self.answer("Should not be asked")] }
        let (engine, home) = try titleEngine(generateTitles: false)
        defer { try? FileManager.default.removeItem(at: home.root) }
        let events = engine.events()
        let conversation = try await engine.newConversation()
        try await engine.send("Hi there", to: conversation.id)
        for await event in events {
            if case .turnFinished = event { break }
        }
        try await Task.sleep(for: .milliseconds(300))
        #expect(StubResponsesProtocol.requestBodies.withLock { $0.count } == 1)
        #expect(try await engine.store.conversation(conversation.id)?.title == "Hi there")
    }

    /// What `kuri -p` opens: it exits as the turn ends, so no title is asked for.
    @Test func noTitleWhenTheClientTurnsThemOff() async throws {
        StubResponsesProtocol.requestBodies.withLock { $0 = [] }
        StubResponsesProtocol.bodies.withLock { $0 = [Self.answer("Hello."), Self.answer("Should not be asked")] }
        let (engine, home) = try titleEngine(generateTitles: nil, titles: false)
        defer { try? FileManager.default.removeItem(at: home.root) }
        let events = engine.events()
        let conversation = try await engine.newConversation()
        try await engine.send("Hi there", to: conversation.id)
        for await event in events {
            if case .turnFinished = event { break }
        }
        try await Task.sleep(for: .milliseconds(300))
        #expect(StubResponsesProtocol.requestBodies.withLock { $0.count } == 1)
        #expect(try await engine.store.conversation(conversation.id)?.title == "Hi there")
    }
}
