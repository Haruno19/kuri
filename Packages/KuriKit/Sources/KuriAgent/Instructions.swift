import Foundation
import KuriInference
import KuriSandbox
import KuriStore

/// Fenced blocks of JSON a client draws natively instead of as code
/// (decision 0026). The client says which it draws; the instructions
/// describe only those.
public enum ReplyBlockKind: String, Sendable, CaseIterable {
    case kpi, chart
}

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
        blocks: Set<ReplyBlockKind> = [],
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

        if !blocks.isEmpty {
            sections.append(blockGuidance(blocks))
        }

        return sections.joined(separator: "\n\n")
    }

    /// The blocks worth describing to a model. Providers without tools are
    /// the on-device model today (decision 0013): its 4,096-token context
    /// can't spare the schema, and it writes JSON unreliably.
    static func blocks(_ blocks: Set<ReplyBlockKind>, for provider: any InferenceProvider) -> Set<ReplyBlockKind> {
        provider.supportsTools ? blocks : []
    }

    /// How to write the blocks the client draws. Kept with the user's own
    /// system prompt too: it says what the chat can show, like the date.
    static func blockGuidance(_ blocks: Set<ReplyBlockKind>) -> String {
        var lines = ["""
            The chat draws these fenced blocks natively instead of showing their code. Use one when figures or a \
            series of numbers are the point of the answer, not for every number, and keep the explanation in prose \
            around it. Put only valid JSON inside, and only numbers you have: never invent data to fill a block.
            """]
        if blocks.contains(.kpi) {
            lines.append("""
                - ```kpi: an array of key figures, up to four in a row: [{"label": "Revenue", "value": "€18.4k", \
                "delta": "+12%", "note": "vs October", "good": "up", "spark": [12.1, 13.4, 15.2, 18.4]}]. `value` is \
                formatted for the reader. Optional: `delta` (signed), `note`, `good` ("down" when a fall is good \
                news, as for costs) and `spark` (a dozen recent values at most, oldest first).
                """)
        }
        if blocks.contains(.chart) {
            lines.append("""
                - ```chart: {"type": "bar", "title": "Monthly revenue", "x": "Month", "y": "Revenue (k€)", \
                "unit": "k€", "data": [{"x": "Jan", "y": 40, "series": "2025"}, {"x": "Jan", "y": 46, "series": "2026"}]}. \
                `type` is bar, line, area or pie; one row per point; `series` only to compare up to five series \
                (pie: no series, five slices at most).
                """)
        }
        return lines.joined(separator: "\n")
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
