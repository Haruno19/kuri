# Decision records

Short records of the decisions that shape Kuri, so they aren't re-argued every time. Each says what was decided, why, and what it costs.

To change one, write a new record that supersedes it, and mark the old one *Superseded by NNNN*. Number them in order.

| # | Decision |
|---|---|
| [0001](0001-single-process-engine.md) | One app, with the engine in-process behind an event stream |
| [0002](0002-stateless-providers.md) | Stateless towards providers; the database is the source of truth |
| [0003](0003-items-not-messages.md) | Conversations are items, not messages |
| [0004](0004-no-app-sandbox.md) | No App Sandbox; safety comes from the VM and tool policies |
| [0005](0005-one-shell-no-file-tools.md) | One shell; no file tools, no artifacts |
| [0006](0006-config-in-files.md) | Configuration in JSON5 files, data in SQLite, secrets in the Keychain |
| [0007](0007-minimal-sqlite.md) | SQLite through the system library, with a small schema |
| [0008](0008-mcp-official-sdk-own-transport.md) | MCP through the official SDK, with our own stdio transport |
| [0009](0009-tool-policies.md) | One policy model for every tool |
| [0010](0010-durable-turns-without-tables.md) | Durable turns without extra tables |
| [0011](0011-compaction-marks-what-it-covers.md) | A compaction names the last item it covers |
| [0012](0012-sandbox-on-containerization.md) | The sandbox: Containerization, one VM per conversation, no network |
| [0013](0013-apple-model-text-only.md) | Apple's on-device model is text only |
| [0014](0014-anthropic-thinking-replay.md) | Anthropic thinking is replayed only within the current exchange |
| [0015](0015-typography.md) | Typography: Publico Text, DM Sans, iA Writer Mono |
| [0016](0016-retry-replaces-the-answer.md) | Retry replaces the answer (amends 0003) |
| [0017](0017-markdown-on-foundation.md) | Markdown on Foundation's parser, with our own highlighter |
| [0018](0018-literata.md) | Literata replaces Publico Text (amends 0015) |
