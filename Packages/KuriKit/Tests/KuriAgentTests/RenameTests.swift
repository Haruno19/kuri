import Foundation
import KuriConfig
import KuriCore
import KuriInference
import KuriStore
import Testing
@testable import KuriAgent

extension EngineTests {
    @Test func renameKeepsTheConversationsPlace() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "kuri-rename-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let home = KuriHome(root: root)
        try home.prepare()
        let engine = Engine(home: home, store: try Store(url: home.database),
                            config: Config(generateTitles: false), mcpConfig: MCPConfig(), factory: ProviderFactory())
        await engine.start()
        defer { Task { await engine.shutdown() } }

        let conversation = try await engine.newConversation()
        let before = try #require(try await engine.store.conversation(conversation.id))
        try await engine.rename(conversation.id, to: "  Trip to Kyoto \n")
        let after = try #require(try await engine.store.conversation(conversation.id))
        #expect(after.title == "Trip to Kyoto")
        // Not activity: the list order (by updatedAt) doesn't change.
        #expect(abs(after.updatedAt.timeIntervalSince(before.updatedAt)) < 0.001)

        // An empty title is ignored.
        try await engine.rename(conversation.id, to: "   ")
        #expect(try await engine.store.conversation(conversation.id)?.title == "Trip to Kyoto")
    }
}
