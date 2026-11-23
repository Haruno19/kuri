import Foundation
import KuriSandbox
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
        mounts: [SandboxMount] = [],
        image: String? = nil,
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

        if tools.contains("shell") {
            sections.append(workspace(mounts, image: image))
        } else if !folders.isEmpty {
            let list = folders.map { "- \($0.path)\($0.readOnly ? " (read-only)" : "")" }.joined(separator: "\n")
            sections.append("""
                Folders attached to this conversation (you can't open them: the sandbox isn't set up yet):
                \(list)
                """)
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

    /// Where things are inside the sandbox, for the `shell` tool.
    static func workspace(_ mounts: [SandboxMount], image: String? = nil) -> String {
        var intro = "Your `shell` tool runs commands in a Linux sandbox with no network access, starting in /work."
        if image == SandboxSettings.kuriImage {
            intro += " It has \(SandboxSettings.kuriImageContents); nothing else can be installed."
        }
        if let scratch = mounts.first, mounts.count == 1, scratch.isScratch {
            return intro + " /work is a scratch folder for this conversation: the user hasn't attached a folder of theirs. Files you create there persist, and the user can open them."
        }
        let list = mounts.map { "- \($0.guestPath) is \($0.hostPath) on the user's Mac\($0.readOnly ? " (read-only)" : "")" }
            .joined(separator: "\n")
        return intro + " The user's folders are mounted there, and changes you make are made to their files:\n" + list
    }
}
