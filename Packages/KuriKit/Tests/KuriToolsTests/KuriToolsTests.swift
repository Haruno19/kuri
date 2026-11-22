import Foundation
import KuriCore
import KuriStore
import Testing
@testable import KuriTools

struct NoInteraction: UserInteraction {
    func clarify(_ request: ClarifyRequest) async throws -> [String: String] { [:] }
    func approve(_ request: ApprovalRequest) async throws -> Bool { false }
}

private func context(_ store: Store, conversation: UUID = UUID()) -> ToolContext {
    ToolContext(conversationID: conversation, turnID: UUID(), callID: "c1", folders: [], store: store,
                interaction: NoInteraction())
}

@Suite struct ToolRegistryTests {
    @Test func exactPolicyBeatsLongestGlobBeatsDefault() async {
        let registry = ToolRegistry(BuiltInTools.all)
        await registry.setPolicies(["*": .ask, "conversation_*": .deny, "conversation_search": .allow, "mem*": .deny])

        let clarify = ClarifyTool(), search = ConversationSearchTool(), memory = MemoryTool()
        #expect(await registry.policy(for: clarify) == .ask)
        #expect(await registry.policy(for: search) == .allow)
        #expect(await registry.policy(for: memory) == .deny)
        #expect(await registry.specs().map(\.name) == ["clarify", "conversation_search", "tasklist"])
    }
}

@Suite struct TaskListToolTests {
    @Test func rejectsTwoTasksInProgress() async throws {
        let args = #"{"tasks":[{"content":"a","status":"in_progress"},{"content":"b","status":"in_progress"}]}"#
        let output = try await TaskListTool().run(arguments: Data(args.utf8), context: context(try Store(url: nil)))
        #expect(output.isError)
    }

    @Test func currentListIsTheLatestSuccessfulCall() {
        let conversation = UUID()
        func item(_ payload: Item.Payload) -> Item { Item(conversationID: conversation, payload: payload) }
        let items = [
            item(.toolCall(ToolCall(id: "1", name: "tasklist", arguments: #"{"tasks":[{"content":"a","status":"pending"}]}"#))),
            item(.toolResult(ToolResult(callID: "1", output: "ok"))),
            item(.toolCall(ToolCall(id: "2", name: "tasklist", arguments: #"{"tasks":[]}"#))),
            item(.toolResult(ToolResult(callID: "2", output: "bad", isError: true))),
        ]
        #expect(TaskListTool.current(in: items).map(\.content) == ["a"])
    }
}

@Suite struct MemoryToolTests {
    @Test func addsUpdatesAndRemoves() async throws {
        let store = try Store(url: nil)
        let tool = MemoryTool()
        let conversation = Conversation()
        try await store.createConversation(conversation)
        let ctx = context(store, conversation: conversation.id)

        _ = try await tool.run(arguments: Data(#"{"action":"add","content":"Uses zsh"}"#.utf8), context: ctx)
        let id = try #require(try await store.memories().first?.id.uuidString)

        _ = try await tool.run(arguments: Data(#"{"action":"update","id":"\#(id)","content":"Uses fish"}"#.utf8), context: ctx)
        #expect(try await store.memories().map(\.content) == ["Uses fish"])

        let newID = try #require(try await store.memories().first?.id.uuidString)
        _ = try await tool.run(arguments: Data(#"{"action":"remove","id":"\#(newID)"}"#.utf8), context: ctx)
        #expect(try await store.memories().isEmpty)
    }
}
