# 0006. Configuration in JSON5 files, data in SQLite, secrets in the Keychain

Status: accepted

## Context
Kuri should be hackable: providers, models and MCP servers editable by hand, and shareable. Duplicating configuration in the database would mean two sources of truth.

## Decision
Providers, models, tool policies, sandbox settings and MCP servers live in `~/.config/kuri/config.json` and `mcp.json`, written in JSON5 and decoded with Foundation's `allowsJSON5` (no extra dependency). `mcp.json` uses the `mcpServers` shape other MCP clients use. The files are watched and hot-reloaded. Secrets are references (`keychain:<name>`, `env:<VAR>`), never values. UI preferences go in `UserDefaults`. Conversations, turns and memories go in SQLite.

## Consequences
- Configuration can be edited by hand, versioned and pasted from other clients' docs.
- When the app edits `config.json` (model registration, toggles), `ConfigEditor` changes it as a generic tree so unknown keys survive, but hand-written comments are lost.
- Nothing about configuration is ever stored in the database.
