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

    @Test func revisingAMemoryArchivesTheOldOne() async throws {
        let store = try Store(url: nil)
        let original = Memory(content: "Prefers tabs", source: .agent)
        try await store.saveMemory(original)
        let revised = try await store.reviseMemory(original.id, content: "Prefers spaces", source: .user)

        #expect(try await store.memories().map(\.content) == ["Prefers spaces"])
        #expect(try await store.memories(includeArchived: true).count == 2)
        #expect(revised.supersedesID == original.id)
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
