import Foundation
import KuriCore
import Testing
@testable import KuriStore

@Suite struct StoreTests {
    let model = ModelRef(provider: "ollama", model: "qwen3:8b")

    @Test func migratesAndRoundTripsConversations() async throws {
        let store = try Store(url: nil)
        let conversation = Conversation(title: "Hello", model: model)
        try await store.createConversation(conversation)
        try await store.setFolders([ConversationFolder(path: "/Users/me/project")], of: conversation.id)

        let loaded = try #require(try await store.conversation(conversation.id))
        #expect(loaded.title == "Hello")
        #expect(loaded.model == model)
        #expect(try await store.folders(of: conversation.id).map(\.path) == ["/Users/me/project"])
        #expect(try await store.conversations().map(\.id) == [conversation.id])
    }

    @Test func appendsItemsInOrderAndSearchesThem() async throws {
        let store = try Store(url: nil)
        let conversation = Conversation(title: "Build")
        try await store.createConversation(conversation)
        let turn = try await store.beginTurn(conversationID: conversation.id, model: model)

        let payloads: [Item.Payload] = [
            .message(Message(role: .user, text: "Why does the migration fail?")),
            .toolCall(ToolCall(id: "c1", name: "shell", arguments: #"{"command":"swift build"}"#)),
            .toolResult(ToolResult(callID: "c1", output: "error: no such table items_fts")),
            .message(Message(role: .assistant, text: "The FTS table is created after its trigger.")),
        ]
        for payload in payloads {
            try await store.append(Item(conversationID: conversation.id, turnID: turn.id, payload: payload))
        }
        try await store.finishTurn(turn.id, status: .completed, stopReason: .endTurn,
                                   usage: Usage(inputTokens: 100, outputTokens: 20))

        #expect(try await store.items(of: conversation.id).map(\.payload) == payloads)

        let hits = try await store.search("migra")
        #expect(hits.count == 1)
        #expect(hits.first?.conversationTitle == "Build")

        let turns = try await store.turns(of: conversation.id)
        #expect(turns.first?.status == .completed)
        #expect(turns.first?.usage.inputTokens == 100)
    }

    @Test func deletingAConversationCascades() async throws {
        let store = try Store(url: nil)
        let conversation = Conversation()
        try await store.createConversation(conversation)
        try await store.append(Item(conversationID: conversation.id, payload: .message(Message(role: .user, text: "gone"))))
        try await store.deleteConversation(conversation.id)
        #expect(try await store.items(of: conversation.id).isEmpty)
        #expect(try await store.search("gone").isEmpty)
    }

    @Test func memoryChangesApplyAtomically() async throws {
        let store = try Store(url: nil)
        let added = try await store.applyMemoryChanges([.add("Prefers tabs"), .add("Uses zsh")], source: .agent)
        guard case .added(let tabs) = added[0] else { Issue.record("expected an add"); return }
        #expect(tabs.handle == "m1")

        try await store.applyMemoryChanges([.update(number: tabs.number, content: "Prefers spaces")], source: .user)
        #expect(try await store.memories().map(\.content) == ["Uses zsh", "Prefers spaces"])
        #expect(try await store.memories(includeArchived: true).count == 3)

        // A failing change rolls back the whole batch.
        await #expect(throws: KuriError.self) {
            try await store.applyMemoryChanges([.add("Kept?"), .remove(number: 99)], source: .agent)
        }
        #expect(try await store.memories().count == 2)

        // So does going over the budget.
        await #expect(throws: KuriError.self) {
            try await store.applyMemoryChanges([.add(String(repeating: "x", count: 50))], source: .agent,
                                               maxTotalCharacters: 40)
        }
        #expect(try await store.memories().count == 2)
    }

    @Test func searchMatchesAnyWordAndFindsNeighbours() async throws {
        let store = try Store(url: nil)
        let conversation = Conversation(title: "Trip")
        try await store.createConversation(conversation)
        for (role, text) in [(Role.user, "Where should I go in March?"), (.assistant, "Kyoto is lovely in spring."),
                             (.user, "Book a ryokan then.")] {
            try await store.append(Item(conversationID: conversation.id, payload: .message(Message(role: role, text: text))))
        }
        let hits = try await store.search("kyoto lisbon")
        #expect(hits.map(\.text) == ["Kyoto is lovely in spring."])
        let (before, after) = try await store.neighbours(of: hits[0].seq, in: conversation.id)
        #expect(before?.role == "user")
        #expect(after?.text == "Book a ryokan then.")
        #expect(try await store.search("kyoto", in: UUID()).isEmpty)
    }

    @Test func migratesV1MemoriesToNumberedOnes() async throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "kuri-migrate-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: url) }
        // Build a v1 database by hand, with one revised memory.
        let old = UUID()
        do {
            let db = try SQLiteDatabase(path: url.path)
            try db.execute(Migrations.v1)
            try db.execute("PRAGMA user_version = 1")
            try db.execute("""
                INSERT INTO memories (id, content, source, status, created_at, updated_at)
                    VALUES ('\(old.uuidString)', 'old', 'agent', 'archived', 1, 2);
                INSERT INTO memories (id, content, source, status, supersedes_id, created_at, updated_at)
                    VALUES ('\(UUID().uuidString)', 'new', 'agent', 'active', '\(old.uuidString)', 2, 2);
                """)
        }
        let store = try Store(url: url)
        let memories = try await store.memories(includeArchived: true)
        #expect(memories.map(\.content) == ["old", "new"])
        #expect(memories.map(\.number) == [1, 2])
        #expect(memories[1].supersedesID == old)
    }

    @Test func recoversInterruptedTurns() async throws {
        let store = try Store(url: nil)
        let conversation = Conversation()
        try await store.createConversation(conversation)
        let turn = try await store.beginTurn(conversationID: conversation.id, model: model)
        try await store.recoverInterruptedTurns()
        #expect(try await store.turns(of: conversation.id).first { $0.id == turn.id }?.status == .failed)
    }
}
