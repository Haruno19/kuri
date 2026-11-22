/// Schema migrations, applied in order. `PRAGMA user_version` records how
/// many have run. Never edit a shipped migration: append a new one.
enum Migrations {
    static let all: [String] = [v1]

    static let v1 = """
        CREATE TABLE conversations (
            id            TEXT PRIMARY KEY,
            parent_id     TEXT REFERENCES conversations(id) ON DELETE CASCADE,
            title         TEXT NOT NULL DEFAULT '',
            model         TEXT,
            system_prompt TEXT,
            pinned        INTEGER NOT NULL DEFAULT 0,
            archived      INTEGER NOT NULL DEFAULT 0,
            created_at    REAL NOT NULL,
            updated_at    REAL NOT NULL
        );
        CREATE INDEX conversations_updated ON conversations(updated_at DESC);

        CREATE TABLE conversation_folders (
            conversation_id TEXT NOT NULL REFERENCES conversations(id) ON DELETE CASCADE,
            path            TEXT NOT NULL,
            read_only       INTEGER NOT NULL DEFAULT 0,
            PRIMARY KEY (conversation_id, path)
        );

        CREATE TABLE turns (
            id               TEXT PRIMARY KEY,
            conversation_id  TEXT NOT NULL REFERENCES conversations(id) ON DELETE CASCADE,
            model            TEXT NOT NULL,
            status           TEXT NOT NULL,
            stop_reason      TEXT,
            error            TEXT,
            input_tokens     INTEGER NOT NULL DEFAULT 0,
            output_tokens    INTEGER NOT NULL DEFAULT 0,
            reasoning_tokens INTEGER NOT NULL DEFAULT 0,
            cached_tokens    INTEGER NOT NULL DEFAULT 0,
            started_at       REAL NOT NULL,
            ended_at         REAL
        );
        CREATE INDEX turns_conversation ON turns(conversation_id, started_at);

        CREATE TABLE items (
            id              TEXT PRIMARY KEY,
            conversation_id TEXT NOT NULL REFERENCES conversations(id) ON DELETE CASCADE,
            turn_id         TEXT REFERENCES turns(id) ON DELETE SET NULL,
            seq             INTEGER NOT NULL,
            kind            TEXT NOT NULL,
            role            TEXT,
            text            TEXT NOT NULL DEFAULT '',
            payload         TEXT NOT NULL,
            created_at      REAL NOT NULL,
            UNIQUE (conversation_id, seq)
        );

        CREATE VIRTUAL TABLE items_fts USING fts5(text, content='items', content_rowid='rowid');
        CREATE TRIGGER items_ai AFTER INSERT ON items BEGIN
            INSERT INTO items_fts(rowid, text) VALUES (new.rowid, new.text);
        END;
        CREATE TRIGGER items_ad AFTER DELETE ON items BEGIN
            INSERT INTO items_fts(items_fts, rowid, text) VALUES ('delete', old.rowid, old.text);
        END;
        CREATE TRIGGER items_au AFTER UPDATE OF text ON items BEGIN
            INSERT INTO items_fts(items_fts, rowid, text) VALUES ('delete', old.rowid, old.text);
            INSERT INTO items_fts(rowid, text) VALUES (new.rowid, new.text);
        END;

        CREATE TABLE memories (
            id                     TEXT PRIMARY KEY,
            content                TEXT NOT NULL,
            source                 TEXT NOT NULL,
            status                 TEXT NOT NULL DEFAULT 'active',
            supersedes_id          TEXT REFERENCES memories(id) ON DELETE SET NULL,
            origin_conversation_id TEXT REFERENCES conversations(id) ON DELETE SET NULL,
            created_at             REAL NOT NULL,
            updated_at             REAL NOT NULL
        );
        """
}
