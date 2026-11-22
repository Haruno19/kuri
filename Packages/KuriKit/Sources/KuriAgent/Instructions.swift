import Foundation
import KuriStore

/// Builds the instructions (system prompt) for a request.
enum Instructions {
    static let base = """
        You are Kuri, an assistant running on the user's Mac. Be direct and concise. Use the tools \
        you have when they help; ask with `clarify` only when you can't resolve an ambiguity yourself. \
        For work with several steps, keep a plan with `tasklist`.
        """

    static func build(
        conversation: Conversation,
        folders: [ConversationFolder],
        memories: [Memory],
        now: Date = .now
    ) -> String {
        var sections = [conversation.systemPrompt ?? base]

        sections.append("Today is \(now.formatted(.dateTime.weekday(.wide).day().month(.wide).year())).")

        if folders.isEmpty {
            sections.append("No folders are attached to this conversation.")
        } else {
            let list = folders.map { "- \($0.path)\($0.readOnly ? " (read-only)" : "")" }.joined(separator: "\n")
            sections.append("Folders attached to this conversation:\n\(list)")
        }

        if !memories.isEmpty {
            let list = memories.map { "- \($0.content)" }.joined(separator: "\n")
            sections.append("""
                What you remember about the user (manage with the `memory` tool):
                \(list)
                """)
        }

        return sections.joined(separator: "\n\n")
    }
}
