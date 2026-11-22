# 0007. SQLite through the system library, with a small schema

Status: accepted

## Context
Kuri needs durable conversations and full-text search, without a database server or an opaque persistence framework. SwiftData would hide the schema and has no full-text search; GRDB is a fine library but a personal one.

## Decision
One SQLite file, opened through the system `sqlite3` library with a thin wrapper of our own, WAL mode, foreign keys on, migrations counted by `PRAGMA user_version` and append-only. Five tables (conversations, folders, turns, items, memories) plus an FTS5 index. Anything derivable isn't stored.

## Consequences
- The file can be inspected with any SQLite tool.
- Queries are hand-written; the wrapper must stay small.
- New state starts from the question "can it be derived from items, or kept in memory?" before it gets a table.
