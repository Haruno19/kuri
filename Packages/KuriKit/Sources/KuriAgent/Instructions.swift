import Foundation
import KuriStore

/// Builds the instructions (system prompt) for a request.
enum Instructions {
    static let intro = "You are Kuri, an assistant running on the user's Mac. Be direct and concise."

    /// Guidance for built-in tools, included only when the tool is available.
    static let toolGuidance: [(tool: String, text: String)] = [
        ("clarify", "Ask with `clarify` only when an ambiguity would change the result and you can't resolve it yourself."),
        ("tasklist", "For work with three or more steps, keep a plan with `tasklist` and update it as you go."),
    ]

    static func build(
        conversation: Conversation,
        folders: [ConversationFolder],
        memories: [Memory],
        tools: Set<String>,
        now: Date = .now
    ) -> String {
        var sections: [String] = []

        if let custom = conversation.systemPrompt {
            sections.append(custom)
        } else {
            let guidance = toolGuidance.filter { tools.contains($0.tool) }.map(\.text)
            sections.append(([intro] + guidance).joined(separator: " "))
        }

        sections.append("Today is \(now.formatted(.dateTime.weekday(.wide).day().month(.wide).year())).")

        if !folders.isEmpty {
            let list = folders.map { "- \($0.path)\($0.readOnly ? " (read-only)" : "")" }.joined(separator: "\n")
            sections.append("Folders attached to this conversation:\n\(list)")
        }

        if tools.contains("memory") || !memories.isEmpty {
            let list = memories.isEmpty
                ? "(empty)"
                : memories.map { "\($0.handle): \($0.content)" }.joined(separator: "\n")
            let howToChange = tools.contains("memory")
                ? " Change it with the `memory` tool, referring to entries by id." : ""
            sections.append("""
                What you remember about the user, from earlier conversations.\(howToChange)
                <user_memory>
                \(list)
                </user_memory>
                """)
        }

        return sections.joined(separator: "\n\n")
    }
}
