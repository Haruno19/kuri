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
    @Test func appliesABatchOfOperations() async throws {
        let store = try Store(url: nil)
        let conversation = Conversation()
        try await store.createConversation(conversation)
        let ctx = context(store, conversation: conversation.id)
        let tool = MemoryTool()

        let first = try await tool.run(arguments: Data(#"{"operations":[{"action":"add","content":"Uses zsh"},{"action":"add","content":"Editor: Helix"}]}"#.utf8), context: ctx)
        #expect(first.text == "Added m1: Uses zsh\nAdded m2: Editor: Helix")

        let second = try await tool.run(arguments: Data(#"{"operations":[{"action":"update","id":"m1","content":"Uses fish"},{"action":"remove","id":"m2"}]}"#.utf8), context: ctx)
        #expect(second.text == "Updated m1, now m3: Uses fish\nRemoved m2")
        #expect(try await store.memories().map(\.handle) == ["m3"])
    }

    @Test func explainsInvalidOperations() async throws {
        let store = try Store(url: nil)
        let output = try await MemoryTool().run(arguments: Data(#"{"operations":[{"action":"update","content":"x"}]}"#.utf8),
                                                context: context(store))
        #expect(output.isError)
        #expect(output.text.contains("id"))
    }
}

@Suite struct ConversationSearchToolTests {
    @Test func groupsHitsByConversationWithContext() async throws {
        let store = try Store(url: nil)
        let past = Conversation(title: "Trip")
        let current = Conversation(title: "Now")
        try await store.createConversation(past)
        try await store.createConversation(current)
        for (role, text) in [(Role.user, "Where should I go?"), (.assistant, "Kyoto in spring."), (.user, "Thanks")] {
            try await store.append(Item(conversationID: past.id, payload: .message(Message(role: role, text: text))))
        }
        let output = try await ConversationSearchTool().run(arguments: Data(#"{"query":"kyoto"}"#.utf8),
                                                            context: context(store, conversation: current.id))
        #expect(output.text.contains(#"<conversation title="Trip""#))
        #expect(output.text.contains("user: Where should I go?\nassistant: Kyoto in spring.\nuser: Thanks"))

        // this_chat only covers what a summary replaced.
        try await store.append(Item(conversationID: current.id, payload: .message(Message(role: .user, text: "Kyoto again?"))))
        let unsummarized = try await ConversationSearchTool().run(arguments: Data(#"{"query":"kyoto","scope":"this_chat"}"#.utf8),
                                                                  context: context(store, conversation: current.id))
        #expect(unsummarized.text.contains("hasn't been summarized"))
        #expect(unsummarized.text.contains(#"<conversation title="Trip""#))  // fell back to other chats

        try await store.append(Item(conversationID: current.id, payload: .compaction(Compaction(summary: "Talked about trips."))))
        try await store.append(Item(conversationID: current.id, payload: .message(Message(role: .user, text: "And Kyoto now?"))))
        let summarized = try await ConversationSearchTool().run(arguments: Data(#"{"query":"kyoto","scope":"this_chat"}"#.utf8),
                                                                context: context(store, conversation: current.id))
        #expect(summarized.text.contains("Kyoto again?"))
        #expect(!summarized.text.contains("And Kyoto now?"))
    }

    @Test func excerptsCentreOnTheMatch() {
        let text = String(repeating: "a ", count: 500) + "needle" + String(repeating: " b", count: 500)
        let excerpt = ConversationSearchTool.excerpt(text, limit: 100, around: ["needle"])
        #expect(excerpt.contains("needle"))
        #expect(excerpt.hasPrefix("…") && excerpt.hasSuffix("…"))
    }
}

@Suite struct ClarifyArgumentTests {
    @Test func acceptsWhatSmallModelsSend() throws {
        let strict = #"{"questions":[{"id":"city","question":"Which city?","options":["Kyoto","Lisbon"]}]}"#
        let stringified = #"{"questions":"[{\"id\": \"city\", \"question\": \"Which city?\", \"options\": [\"Kyoto\"]}]"}"#
        let objectOptions = #"{"questions":[{"question":"Which city?","options":[{"id":"k","name":"Kyoto"},{"label":"Lisbon"}]}]}"#
        let decoder = JSONDecoder()
        #expect(try decoder.decode(ClarifyTool.Arguments.self, from: Data(strict.utf8)).questions.first?.options == ["Kyoto", "Lisbon"])
        #expect(try decoder.decode(ClarifyTool.Arguments.self, from: Data(stringified.utf8)).questions.first?.id == "city")
        let fixed = try decoder.decode(ClarifyTool.Arguments.self, from: Data(objectOptions.utf8)).questions
        #expect(fixed.first?.id == "q1")
        #expect(fixed.first?.options == ["Kyoto", "Lisbon"])
    }
}
