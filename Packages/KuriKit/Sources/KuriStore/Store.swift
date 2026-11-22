import Foundation
import KuriCore

/// The SQLite file: conversations, turns, items, memories.
///
/// An actor, so every access is serialized on one connection. Queries are
/// small and local; there's no need for a connection pool.
public actor Store {
    private let db: SQLiteDatabase

    /// Opens the database at `url`, or an in-memory one when `url` is `nil`.
    public init(url: URL?) throws {
        db = try SQLiteDatabase(path: url?.path(percentEncoded: false) ?? ":memory:")
        try Self.migrate(db)
    }

    private static func migrate(_ db: SQLiteDatabase) throws {
        let current = try db.userVersion
        for (index, sql) in Migrations.all.enumerated() where index >= current {
            try db.transaction {
                try db.execute(sql)
                try db.execute("PRAGMA user_version = \(index + 1)")
            }
        }
    }

    // MARK: Conversations

    public func createConversation(_ conversation: Conversation) throws {
        try db.run("""
            INSERT INTO conversations (id, parent_id, title, model, system_prompt, pinned, archived, created_at, updated_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
            """,
            .uuid(conversation.id), .optional(conversation.parentID), .text(conversation.title),
            .optional(conversation.model?.description), .optional(conversation.systemPrompt),
            .bool(conversation.pinned), .bool(conversation.archived),
            .date(conversation.createdAt), .date(conversation.updatedAt))
    }

    public func updateConversation(_ conversation: Conversation) throws {
        try db.run("""
            UPDATE conversations SET title = ?, model = ?, system_prompt = ?, pinned = ?, archived = ?, updated_at = ?
            WHERE id = ?
            """,
            .text(conversation.title), .optional(conversation.model?.description),
            .optional(conversation.systemPrompt), .bool(conversation.pinned), .bool(conversation.archived),
            .date(conversation.updatedAt), .uuid(conversation.id))
    }

    public func deleteConversation(_ id: UUID) throws {
        try db.run("DELETE FROM conversations WHERE id = ?", .uuid(id))
    }

    public func conversation(_ id: UUID) throws -> Conversation? {
        try db.query("SELECT \(Self.conversationColumns) FROM conversations WHERE id = ?", .uuid(id), map: Self.conversation).first
    }

    /// Top-level conversations, pinned first, then most recently updated.
    public func conversations(includeArchived: Bool = false) throws -> [Conversation] {
        try db.query("""
            SELECT \(Self.conversationColumns) FROM conversations
            WHERE parent_id IS NULL AND (archived = 0 OR ?)
            ORDER BY pinned DESC, updated_at DESC
            """, .bool(includeArchived), map: Self.conversation)
    }

    public func folders(of conversationID: UUID) throws -> [ConversationFolder] {
        try db.query("SELECT path, read_only FROM conversation_folders WHERE conversation_id = ? ORDER BY path",
                     .uuid(conversationID)) { ConversationFolder(path: $0.string(0), readOnly: $0.bool(1)) }
    }

    public func setFolders(_ folders: [ConversationFolder], of conversationID: UUID) throws {
        try db.transaction {
            try db.run("DELETE FROM conversation_folders WHERE conversation_id = ?", .uuid(conversationID))
            for folder in folders {
                try db.run("INSERT INTO conversation_folders (conversation_id, path, read_only) VALUES (?, ?, ?)",
                           .uuid(conversationID), .text(folder.path), .bool(folder.readOnly))
            }
        }
    }

    private static let conversationColumns =
        "id, parent_id, title, model, system_prompt, pinned, archived, created_at, updated_at"

    private static func conversation(_ row: Row) -> Conversation {
        Conversation(
            id: row.uuid(0), parentID: row.optionalUUID(1), title: row.string(2),
            model: row.optionalString(3).flatMap(ModelRef.init), systemPrompt: row.optionalString(4),
            pinned: row.bool(5), archived: row.bool(6), createdAt: row.date(7), updatedAt: row.date(8))
    }

    // MARK: Items

    /// Appends an item at the end of its conversation and bumps the
    /// conversation's `updated_at`.
    public func append(_ item: Item) throws {
        let body = String(decoding: try item.payload.encodedBody(), as: UTF8.self)
        let role: String? = if case .message(let message) = item.payload { message.role.rawValue } else { nil }
        try db.transaction {
            try db.run("""
                INSERT INTO items (id, conversation_id, turn_id, seq, kind, role, text, payload, created_at)
                VALUES (?, ?, ?, (SELECT COALESCE(MAX(seq), 0) + 1 FROM items WHERE conversation_id = ?), ?, ?, ?, ?, ?)
                """,
                .uuid(item.id), .uuid(item.conversationID), .optional(item.turnID), .uuid(item.conversationID),
                .text(item.payload.kind), .optional(role), .text(item.payload.searchableText), .text(body),
                .date(item.createdAt))
            try db.run("UPDATE conversations SET updated_at = ? WHERE id = ?", .date(item.createdAt), .uuid(item.conversationID))
        }
    }

    public func items(of conversationID: UUID) throws -> [Item] {
        try db.query("""
            SELECT id, conversation_id, turn_id, kind, payload, created_at FROM items
            WHERE conversation_id = ? ORDER BY seq
            """, .uuid(conversationID)) { row in
            Item(
                id: row.uuid(0), conversationID: row.uuid(1), turnID: row.optionalUUID(2),
                createdAt: row.date(5),
                payload: try Item.Payload(kind: row.string(3), body: Data(row.string(4).utf8)))
        }
    }

    /// Full-text search over every item. `query` uses FTS5 syntax; plain
    /// words are matched as a phrase prefix.
    public func search(_ query: String, limit: Int = 20) throws -> [SearchHit] {
        let terms = query.split(whereSeparator: \.isWhitespace)
            .map { "\"\($0.replacingOccurrences(of: "\"", with: "\"\""))\"*" }
            .joined(separator: " ")
        guard !terms.isEmpty else { return [] }
        return try db.query("""
            SELECT i.conversation_id, c.title, i.id, snippet(items_fts, 0, '[', ']', '…', 12), i.created_at
            FROM items_fts f
            JOIN items i ON i.rowid = f.rowid
            JOIN conversations c ON c.id = i.conversation_id
            WHERE items_fts MATCH ? AND i.kind IN ('message', 'compaction')
            ORDER BY rank LIMIT ?
            """, .text(terms), .int(limit)) { row in
            SearchHit(conversationID: row.uuid(0), conversationTitle: row.string(1), itemID: row.uuid(2),
                      snippet: row.string(3), createdAt: row.date(4))
        }
    }

    // MARK: Turns

    public func beginTurn(id: UUID = UUID(), conversationID: UUID, model: ModelRef, at date: Date = .now) throws -> Turn {
        let turn = Turn(id: id, conversationID: conversationID, model: model, status: .running,
                        usage: Usage(), startedAt: date)
        try db.run("INSERT INTO turns (id, conversation_id, model, status, started_at) VALUES (?, ?, ?, ?, ?)",
                   .uuid(turn.id), .uuid(conversationID), .text(model.description), .text(turn.status.rawValue),
                   .date(date))
        return turn
    }

    public func setTurnStatus(_ id: UUID, _ status: Turn.Status) throws {
        try db.run("UPDATE turns SET status = ? WHERE id = ?", .text(status.rawValue), .uuid(id))
    }

    public func finishTurn(_ id: UUID, status: Turn.Status, stopReason: StopReason?, usage: Usage,
                           error: String? = nil, at date: Date = .now) throws {
        try db.run("""
            UPDATE turns SET status = ?, stop_reason = ?, error = ?, input_tokens = ?, output_tokens = ?,
                reasoning_tokens = ?, cached_tokens = ?, ended_at = ?
            WHERE id = ?
            """,
            .text(status.rawValue), .optional(stopReason?.rawValue), .optional(error),
            .int(usage.inputTokens), .int(usage.outputTokens), .int(usage.reasoningTokens),
            .int(usage.cachedInputTokens), .date(date), .uuid(id))
    }

    public func turns(of conversationID: UUID) throws -> [Turn] {
        try db.query("""
            SELECT id, conversation_id, model, status, stop_reason, error, input_tokens, output_tokens,
                   reasoning_tokens, cached_tokens, started_at, ended_at
            FROM turns WHERE conversation_id = ? ORDER BY started_at
            """, .uuid(conversationID)) { row in
            Turn(
                id: row.uuid(0), conversationID: row.uuid(1),
                model: ModelRef(row.string(2)) ?? ModelRef(provider: "?", model: row.string(2)),
                status: Turn.Status(rawValue: row.string(3)) ?? .failed,
                stopReason: row.optionalString(4).map(StopReason.init(rawValue:)), error: row.optionalString(5),
                usage: Usage(inputTokens: row.int(6), outputTokens: row.int(7),
                             reasoningTokens: row.int(8), cachedInputTokens: row.int(9)),
                startedAt: row.date(10), endedAt: row.optionalDate(11))
        }
    }

    /// Marks turns left `running` by a previous launch as failed. Turns
    /// awaiting input stay as they are: their question is still answerable.
    public func recoverInterruptedTurns(at date: Date = .now) throws {
        try db.run("UPDATE turns SET status = 'failed', error = 'Interrupted', ended_at = ? WHERE status = 'running'",
                   .date(date))
    }

    // MARK: Memories

    public func memories(includeArchived: Bool = false) throws -> [Memory] {
        try db.query("""
            SELECT id, content, source, status, supersedes_id, origin_conversation_id, created_at, updated_at
            FROM memories WHERE status = 'active' OR ? ORDER BY created_at
            """, .bool(includeArchived)) { row in
            Memory(
                id: row.uuid(0), content: row.string(1),
                source: Memory.Source(rawValue: row.string(2)) ?? .user,
                status: Memory.Status(rawValue: row.string(3)) ?? .active,
                supersedesID: row.optionalUUID(4), originConversationID: row.optionalUUID(5),
                createdAt: row.date(6), updatedAt: row.date(7))
        }
    }

    public func saveMemory(_ memory: Memory) throws {
        try db.run("""
            INSERT INTO memories (id, content, source, status, supersedes_id, origin_conversation_id, created_at, updated_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET content = excluded.content, status = excluded.status,
                updated_at = excluded.updated_at
            """,
            .uuid(memory.id), .text(memory.content), .text(memory.source.rawValue), .text(memory.status.rawValue),
            .optional(memory.supersedesID), .optional(memory.originConversationID),
            .date(memory.createdAt), .date(memory.updatedAt))
    }

    /// Replaces a memory's content, keeping the old version archived.
    public func reviseMemory(_ id: UUID, content: String, source: Memory.Source, at date: Date = .now) throws -> Memory {
        let revised = Memory(content: content, source: source, supersedesID: id, createdAt: date, updatedAt: date)
        try db.transaction {
            try db.run("UPDATE memories SET status = 'archived', updated_at = ? WHERE id = ?", .date(date), .uuid(id))
            guard db.changes == 1 else { throw KuriError.database("No memory with id \(id).") }
            try saveMemory(revised)
        }
        return revised
    }

    public func archiveMemory(_ id: UUID, at date: Date = .now) throws {
        try db.run("UPDATE memories SET status = 'archived', updated_at = ? WHERE id = ?", .date(date), .uuid(id))
        guard db.changes == 1 else { throw KuriError.database("No memory with id \(id).") }
    }
}
