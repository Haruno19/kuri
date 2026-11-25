import Foundation
import KuriStore
import Testing
@testable import KuriAgent

@Suite struct ReplyBlockInstructionsTests {
    private let conversation = Conversation(title: "Test")

    /// Blocks are described only when the client draws them, and only those it draws.
    @Test func describesOnlyTheBlocksTheClientDraws() {
        let none = Instructions.build(conversation: conversation, folders: [], memories: [], tools: [])
        #expect(!none.contains("```kpi") && !none.contains("```chart"))
        let charts = Instructions.build(conversation: conversation, folders: [], memories: [], tools: [], blocks: [.chart])
        #expect(charts.contains("```chart") && !charts.contains("```kpi"))
    }

    /// The user's own system prompt replaces the introduction, not what the chat can show.
    @Test func keptWithACustomSystemPrompt() {
        var custom = conversation
        custom.systemPrompt = "Answer like a pirate."
        let text = Instructions.build(conversation: custom, folders: [], memories: [], tools: [], blocks: Set(ReplyBlockKind.allCases))
        #expect(text.hasPrefix("Answer like a pirate.") && text.contains("```kpi") && text.contains("```chart"))
    }
}
