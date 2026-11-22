import Foundation
import KuriCore
import KuriStore

/// Long-term memory across conversations.
///
/// Active memories are included in every conversation's instructions, so
/// the model mostly needs `add`, `update` and `remove`; `list` shows ids.
public struct MemoryTool: Tool {
    public init() {}

    public let spec = ToolSpec(
        name: "memory",
        description: """
            Manage long-term memories that carry over to future conversations. Save durable facts about \
            the user and their preferences or projects, not details that only matter now. Update a memory \
            instead of adding a near-duplicate. Actions: add (content), update (id, content), remove (id), list.
            """,
        parameters: [
            "type": "object",
            "properties": [
                "action": ["type": "string", "enum": ["add", "update", "remove", "list"]],
                "id": ["type": "string", "description": "Memory id, for update and remove."],
                "content": ["type": "string", "description": "One self-contained fact, for add and update."],
            ],
            "required": ["action"],
        ])

    private struct Arguments: Decodable {
        let action: String
        let id: String?
        let content: String?
    }

    static let maxLength = 500

    public func run(arguments: Data, context: ToolContext) async throws -> ToolOutput {
        let args = try decode(Arguments.self, from: arguments)
        let store = context.store

        switch args.action {
        case "list":
            let memories = try await store.memories()
            if memories.isEmpty { return ToolOutput("No memories yet.") }
            return ToolOutput(memories.map { "[\($0.id.uuidString.lowercased())] \($0.content)" }.joined(separator: "\n"))

        case "add":
            guard let content = try validContent(args.content) else { return .error("`content` is required.") }
            let memory = Memory(content: content, source: .agent, originConversationID: context.conversationID)
            try await store.saveMemory(memory)
            return ToolOutput("Saved memory \(memory.id.uuidString.lowercased()).")

        case "update":
            guard let id = args.id.flatMap(UUID.init(uuidString:)) else { return .error("A valid `id` is required.") }
            guard let content = try validContent(args.content) else { return .error("`content` is required.") }
            let revised = try await store.reviseMemory(id, content: content, source: .agent)
            return ToolOutput("Updated; the memory's new id is \(revised.id.uuidString.lowercased()).")

        case "remove":
            guard let id = args.id.flatMap(UUID.init(uuidString:)) else { return .error("A valid `id` is required.") }
            try await store.archiveMemory(id)
            return ToolOutput("Removed.")

        default:
            return .error("Unknown action “\(args.action)”. Use add, update, remove or list.")
        }
    }

    private func validContent(_ content: String?) throws -> String? {
        guard let content = content?.trimmingCharacters(in: .whitespacesAndNewlines), !content.isEmpty else { return nil }
        guard content.count <= Self.maxLength else {
            throw KuriError.invalidToolArguments(tool: spec.name, reason: "keep a memory under \(Self.maxLength) characters")
        }
        return content
    }
}
