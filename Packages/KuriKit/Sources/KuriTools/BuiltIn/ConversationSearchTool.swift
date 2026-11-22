import Foundation
import KuriCore

/// Full-text search over past conversations.
public struct ConversationSearchTool: Tool {
    public init() {}

    public let spec = ToolSpec(
        name: "conversation_search",
        description: """
            Search past conversations by keywords. Use it when the user refers to something discussed \
            before that isn't in this conversation.
            """,
        parameters: [
            "type": "object",
            "properties": [
                "query": ["type": "string", "description": "Keywords. Prefixes match: \"migra\" finds \"migration\"."],
                "limit": ["type": "integer", "minimum": 1, "maximum": 50],
            ],
            "required": ["query"],
        ])

    private struct Arguments: Decodable {
        let query: String
        let limit: Int?
    }

    public var isReadOnly: Bool { true }

    public func run(arguments: Data, context: ToolContext) async throws -> ToolOutput {
        let args = try decode(Arguments.self, from: arguments)
        let hits = try await context.store.search(args.query, limit: min(max(args.limit ?? 10, 1), 50))
            .filter { $0.conversationID != context.conversationID }
        guard !hits.isEmpty else { return ToolOutput("No matches.") }

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withFullDate]
        return ToolOutput(hits.map { hit in
            let title = hit.conversationTitle.isEmpty ? "Untitled" : hit.conversationTitle
            return "• \(title) (\(formatter.string(from: hit.createdAt))): \(hit.snippet)"
        }.joined(separator: "\n"))
    }
}
