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

    /// Deletes every item after `itemID` in its conversation, returning
    /// their ids in order. Retrying an answer is the one time items leave
    /// the database (decision 0016); the search index follows by trigger.
    public func removeItems(after itemID: UUID, in conversationID: UUID) throws -> [UUID] {
        try db.transaction {
            let ids = try db.query("""
                SELECT id FROM items
                WHERE conversation_id = ? AND seq > (SELECT seq FROM items WHERE id = ?) ORDER BY seq
                """, .uuid(conversationID), .uuid(itemID)) { $0.uuid(0) }
            try db.run("""
                DELETE FROM items WHERE conversation_id = ? AND seq > (SELECT seq FROM items WHERE id = ?)
                """, .uuid(conversationID), .uuid(itemID))
            return ids
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

    /// Full-text search over messages and compaction summaries.
    ///
    /// Any of the words may match, as a prefix; results with more of them
    /// rank first. Pass `conversationID` to search one conversation only
    /// (optionally only items before `seq`), or `excluded` to leave one out.
    public func search(_ query: String, in conversationID: UUID? = nil, before seq: Int? = nil,
                       excluding excluded: UUID? = nil, limit: Int = 10) throws -> [SearchHit] {
        let terms = query.split(whereSeparator: { $0.isWhitespace || $0.isPunctuation })
            .map { "\"\($0.replacingOccurrences(of: "\"", with: "\"\""))\"*" }
            .joined(separator: " OR ")
        guard !terms.isEmpty else { return [] }
        return try db.query("""
            SELECT i.conversation_id, c.title, i.id, i.seq, i.role, i.text, i.created_at
            FROM items_fts f
            JOIN items i ON i.rowid = f.rowid
            JOIN conversations c ON c.id = i.conversation_id
            WHERE items_fts MATCH ? AND i.kind IN ('message', 'compaction')
                AND (? IS NULL OR i.conversation_id = ?) AND (? IS NULL OR i.conversation_id != ?)
                AND (? IS NULL OR i.seq < ?)
            ORDER BY rank LIMIT ?
            """, .text(terms), .optional(conversationID), .optional(conversationID), .optional(excluded),
            .optional(excluded), .optional(seq), .optional(seq), .int(limit)) { row in
            SearchHit(conversationID: row.uuid(0), conversationTitle: row.string(1), itemID: row.uuid(2),
                      seq: row.int(3), role: row.optionalString(4), text: row.string(5), createdAt: row.date(6))
        }
    }

    /// The position of the last item the latest compaction summarized, if
    /// the conversation was ever compacted. Items up to it are no longer in
    /// the model's context.
    public func compactedThroughSeq(in conversationID: UUID) throws -> Int? {
        let latest = try db.query("""
            SELECT seq, payload FROM items WHERE conversation_id = ? AND kind = 'compaction'
            ORDER BY seq DESC LIMIT 1
            """, .uuid(conversationID)) { (seq: $0.int(0), payload: $0.string(1)) }.first
        guard let latest else { return nil }
        guard let compaction = try? JSONDecoder().decode(Compaction.self, from: Data(latest.payload.utf8)),
              let through = compaction.throughItemID
        else { return latest.seq - 1 }
        return try db.query("SELECT seq FROM items WHERE id = ?", .uuid(through)) { $0.int(0) }.first ?? latest.seq - 1
    }

    /// The messages just before and after `seq` in a conversation, for
    /// showing a search hit in context.
    /// Neither goes past `limit`, when given.
    public func neighbours(of seq: Int, in conversationID: UUID, before limit: Int? = nil) throws
        -> (before: SearchHit?, after: SearchHit?)
    {
        func fetch(_ comparison: String, _ order: String) throws -> SearchHit? {
            try db.query("""
                SELECT i.conversation_id, c.title, i.id, i.seq, i.role, i.text, i.created_at
                FROM items i JOIN conversations c ON c.id = i.conversation_id
                WHERE i.conversation_id = ? AND i.kind = 'message' AND i.seq \(comparison) ? AND (? IS NULL OR i.seq < ?)
                ORDER BY i.seq \(order) LIMIT 1
                """, .uuid(conversationID), .int(seq), .optional(limit), .optional(limit)) { row in
                SearchHit(conversationID: row.uuid(0), conversationTitle: row.string(1), itemID: row.uuid(2),
                          seq: row.int(3), role: row.optionalString(4), text: row.string(5), createdAt: row.date(6))
            }.first
        }
        return (try fetch("<", "DESC"), try fetch(">", "ASC"))
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
        try db.query("SELECT \(Self.turnColumns) FROM turns WHERE conversation_id = ? ORDER BY started_at",
                     .uuid(conversationID), map: Self.turn)
    }

    public func turns(withStatus status: Turn.Status) throws -> [Turn] {
        try db.query("SELECT \(Self.turnColumns) FROM turns WHERE status = ? ORDER BY started_at",
                     .text(status.rawValue), map: Self.turn)
    }

    private static let turnColumns = """
        id, conversation_id, model, status, stop_reason, error, input_tokens, output_tokens,
        reasoning_tokens, cached_tokens, started_at, ended_at
        """

    private static func turn(_ row: Row) -> Turn {
        Turn(
            id: row.uuid(0), conversationID: row.uuid(1),
            model: ModelRef(row.string(2)) ?? ModelRef(provider: "?", model: row.string(2)),
            status: Turn.Status(rawValue: row.string(3)) ?? .failed,
            stopReason: row.optionalString(4).map(StopReason.init(rawValue:)), error: row.optionalString(5),
            usage: Usage(inputTokens: row.int(6), outputTokens: row.int(7),
                         reasoningTokens: row.int(8), cachedInputTokens: row.int(9)),
            startedAt: row.date(10), endedAt: row.optionalDate(11))
    }

    /// Marks turns left `running` by a previous launch as failed. Turns
    /// awaiting input stay as they are: their question is still answerable.
    public func recoverInterruptedTurns(at date: Date = .now) throws {
        try db.run("UPDATE turns SET status = 'failed', error = 'Interrupted', ended_at = ? WHERE status = 'running'",
                   .date(date))
    }

    // MARK: Memories

    private static let memoryColumns =
        "number, id, content, source, status, supersedes_id, origin_conversation_id, created_at, updated_at"

    private static func memory(_ row: Row) -> Memory {
        Memory(
            number: row.int(0), id: row.uuid(1), content: row.string(2),
            source: Memory.Source(rawValue: row.string(3)) ?? .user,
            status: Memory.Status(rawValue: row.string(4)) ?? .active,
            supersedesID: row.optionalUUID(5), originConversationID: row.optionalUUID(6),
            createdAt: row.date(7), updatedAt: row.date(8))
    }

    public func memories(includeArchived: Bool = false) throws -> [Memory] {
        try db.query("SELECT \(Self.memoryColumns) FROM memories WHERE status = 'active' OR ? ORDER BY number",
                     .bool(includeArchived), map: Self.memory)
    }

    /// Applies a batch of changes atomically: either all of them land, or
    /// none do. Fails if a change targets a memory that isn't active, or if
    /// the active memories would exceed `maxTotalCharacters` afterwards.
    @discardableResult
    public func applyMemoryChanges(
        _ changes: [MemoryChange],
        source: Memory.Source,
        originConversationID: UUID? = nil,
        maxTotalCharacters: Int? = nil,
        at date: Date = .now
    ) throws -> [MemoryChangeOutcome] {
        try db.transaction {
            var outcomes: [MemoryChangeOutcome] = []
            for change in changes {
                switch change {
                case .add(let content):
                    let memory = try insertMemory(content, source: source, supersedes: nil,
                                                  origin: originConversationID, at: date)
                    outcomes.append(.added(memory))
                case .update(let number, let content):
                    let old = try archiveActiveMemory(number, at: date)
                    let memory = try insertMemory(content, source: source, supersedes: old,
                                                  origin: originConversationID, at: date)
                    outcomes.append(.updated(old: number, new: memory))
                case .remove(let number):
                    _ = try archiveActiveMemory(number, at: date)
                    outcomes.append(.removed(number))
                }
            }
            if let maxTotalCharacters {
                let total = try db.query("SELECT COALESCE(SUM(LENGTH(content)), 0) FROM memories WHERE status = 'active'") {
                    $0.int(0)
                }.first ?? 0
                if total > maxTotalCharacters {
                    throw KuriError.memoryFull(total: total, limit: maxTotalCharacters)
                }
            }
            return outcomes
        }
    }

    private func insertMemory(_ content: String, source: Memory.Source, supersedes: UUID?, origin: UUID?,
                              at date: Date) throws -> Memory {
        let id = UUID()
        try db.run("""
            INSERT INTO memories (id, content, source, status, supersedes_id, origin_conversation_id, created_at, updated_at)
            VALUES (?, ?, ?, 'active', ?, ?, ?, ?)
            """,
            .uuid(id), .text(content), .text(source.rawValue), .optional(supersedes), .optional(origin),
            .date(date), .date(date))
        return Memory(number: db.lastInsertRowID, id: id, content: content, source: source, supersedesID: supersedes,
                      originConversationID: origin, createdAt: date, updatedAt: date)
    }

    /// Archives an active memory and returns its id.
    private func archiveActiveMemory(_ number: Int, at date: Date) throws -> UUID {
        guard let id = try db.query("SELECT id FROM memories WHERE number = ? AND status = 'active'", .int(number), map: {
            $0.uuid(0)
        }).first else {
            throw KuriError.memoryNotFound(number)
        }
        try db.run("UPDATE memories SET status = 'archived', updated_at = ? WHERE number = ?", .date(date), .int(number))
        return id
    }
}
