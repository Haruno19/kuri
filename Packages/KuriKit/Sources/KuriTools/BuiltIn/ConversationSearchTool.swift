import Foundation
import KuriCore
import KuriStore

/// Full-text search over the user's conversations.
///
/// Two uses: the user refers to something discussed in another
/// conversation, or — after compaction — the model needs an exact detail of
/// this conversation that is no longer in its context.
public struct ConversationSearchTool: Tool {
    static let defaultLimit = 5
    static let maxLimit = 10
    /// Characters of the matching message, around the first matched word.
    static let matchCharacters = 1_200
    /// Characters of each neighbouring message.
    static let contextCharacters = 400

    public init() {}

    public let spec = ToolSpec(
        name: "conversation_search",
        description: """
            Searches the user's past conversations with you and returns each matching message with the \
            messages around it. Use it when the user refers to something discussed before ("as we said last \
            week"), and with scope this_chat when you need an exact detail of this conversation that was \
            summarized and is no longer in your context: search for it instead of guessing.
            """,
        parameters: [
            "type": "object",
            "properties": [
                "query": [
                    "type": "string",
                    "description": "Words to look for: names, numbers, topics. Any of them can match; messages with more of them come first.",
                ],
                "scope": [
                    "type": "string",
                    "enum": ["other_chats", "this_chat"],
                    "description": "other_chats: every conversation except this one (default). this_chat: only this one.",
                ],
                "limit": ["type": "integer", "minimum": 1, "maximum": 10, "description": "Matches to return. Default 5."],
            ],
            "required": ["query"],
        ])

    private struct Arguments: Decodable {
        let query: String
        let scope: String?
        let limit: Int?
    }

    public var isReadOnly: Bool { true }

    public func run(arguments: Data, context: ToolContext) async throws -> ToolOutput {
        let args = try decode(Arguments.self, from: arguments)
        let limit = min(max(args.limit ?? Self.defaultLimit, 1), Self.maxLimit)
        let thisChat = args.scope == "this_chat"
        let words = Self.words(in: args.query)

        let hits = try await context.store.search(
            args.query, in: thisChat ? context.conversationID : nil, excluding: thisChat ? nil : context.conversationID,
            limit: limit)
        guard !hits.isEmpty else { return ToolOutput("No matches for “\(args.query)”.") }

        // Group by conversation, keeping the rank order of each one's best hit.
        var order: [UUID] = []
        var groups: [UUID: [SearchHit]] = [:]
        for hit in hits {
            if groups[hit.conversationID] == nil { order.append(hit.conversationID) }
            groups[hit.conversationID, default: []].append(hit)
        }

        var sections: [String] = []
        for conversationID in order {
            let group = groups[conversationID]!
            let title = group[0].conversationTitle.isEmpty ? "Untitled" : group[0].conversationTitle
            var excerpts: [String] = []
            for hit in group.sorted(by: { $0.seq < $1.seq }) {
                let (before, after) = try await context.store.neighbours(of: hit.seq, in: conversationID)
                var lines: [String] = []
                if let before { lines.append(Self.line(before, limit: Self.contextCharacters, words: words)) }
                lines.append(Self.line(hit, limit: Self.matchCharacters, words: words))
                if let after { lines.append(Self.line(after, limit: Self.contextCharacters, words: words)) }
                excerpts.append("<excerpt>\n\(lines.joined(separator: "\n"))\n</excerpt>")
            }
            sections.append("""
                <conversation title="\(title)" date="\(Self.date(group[0].createdAt))">
                \(excerpts.joined(separator: "\n"))
                </conversation>
                """)
        }
        return ToolOutput(sections.joined(separator: "\n"))
    }

    private static func line(_ hit: SearchHit, limit: Int, words: [String]) -> String {
        "\(hit.role ?? "summary"): \(excerpt(hit.text, limit: limit, around: words))"
    }

    static func words(in query: String) -> [String] {
        query.split(whereSeparator: { $0.isWhitespace || $0.isPunctuation }).map { $0.lowercased() }
    }

    /// At most `limit` characters of `text`, centred on the first matched
    /// word: in a long answer the relevant part is rarely at the start.
    static func excerpt(_ text: String, limit: Int, around words: [String]) -> String {
        guard text.count > limit else { return text }
        let lower = text.lowercased()
        let hit = words.compactMap { lower.range(of: $0)?.lowerBound }.min()
        let centre = hit.map { lower.distance(from: lower.startIndex, to: $0) } ?? 0
        let start = max(0, min(centre - limit / 3, text.count - limit))
        let from = text.index(text.startIndex, offsetBy: start)
        let to = text.index(from, offsetBy: limit)
        return (start > 0 ? "…" : "") + text[from..<to] + (to < text.endIndex ? "…" : "")
    }

    private static func date(_ date: Date) -> String {
        date.formatted(.iso8601.year().month().day())
    }
}
