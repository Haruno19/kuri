# Kuri

A native macOS app for working with language models — local or hosted — that can chat, think, and act on your files from a sandbox.

Kuri is a single app that is both the engine and the interface: no server to deploy, no database service, no Docker. It runs offline with local models, talks to any hosted provider when you want it to, discovers MCP servers at runtime, and runs the model's commands inside a lightweight Linux VM.

> Status: early draft. The architecture below is the plan; the code implements the foundations (domain model, config, storage, the Open Responses adapter, built-in tools, the agent loop) and a bare app shell.

---

## Principles

- **Essential.** Few features, done well. Few dependencies, and only official ones (Apple, or the protocol's own SDK). No "personal" or small third-party libraries.
- **Local-first.** Works with no network. Hosted providers are opt-in.
- **Mac-only, Mac-native.** SwiftUI + AppKit, Apple frameworks, macOS conventions. No cross-platform abstractions.
- **Hackable.** Providers, models and MCP servers live in plain JSON5 files you can edit by hand. The database is a plain SQLite file with a small, readable schema.
- **Provider-agnostic.** Every major wire format is a first-class adapter. Switching model mid-conversation just works.
- **One mode.** There is no "chat mode" vs "code mode". Every conversation has the same tools; attaching a folder is what lets the model work on your files.

## Requirements

- Apple silicon Mac, macOS 26 or later (Containerization requires it)
- Xcode 26 or later

## Repository layout

```
Kuri/
├─ Kuri.xcodeproj         The app target. Sources are a folder-synchronized group.
├─ App/                   SwiftUI app: windows, menu bar, settings, views
├─ Packages/KuriKit/      Everything that is not UI, as a local Swift package
│  ├─ Sources/
│  │  ├─ KuriCore/        Domain types. No dependencies.
│  │  ├─ KuriConfig/      ~/.kuri paths, JSON5 config, secrets
│  │  ├─ KuriStore/       SQLite storage
│  │  ├─ KuriInference/   Provider protocol, SSE, wire-format adapters
│  │  ├─ KuriTools/       Tool protocol, registry, permissions, built-in tools
│  │  └─ KuriAgent/       The engine: turn loop, interaction broker, events
│  └─ Tests/
└─ Sketches/              UI experiments (not part of the build)
```

Build the app from Xcode (`Kuri` scheme). The package builds and tests on its own:

```bash
cd Packages/KuriKit && swift test
```

---

## Architecture

### Overview

```
┌──────────────────────────────── Kuri.app ────────────────────────────────┐
│                                                                          │
│  App (SwiftUI)   main window · mini panel · menu bar · settings          │
│        │  observes EngineEvents, calls Engine methods                    │
│        ▼                                                                 │
│  KuriAgent       Engine (actor) ── TurnRunner ── InteractionBroker       │
│        │                │               │                                │
│        ▼                ▼               ▼                                │
│  KuriInference      KuriTools       KuriStore        KuriConfig          │
│  adapters           registry,       SQLite file      JSON5 files,        │
│  (HTTP + SSE)       built-ins,                       Keychain            │
│                     MCP, sandbox                                         │
│        └──────────────────┴──── KuriCore (domain types) ────┘            │
│                                                                          │
│  SandboxService.xpc  (planned) Containerization, isolated from the app   │
└──────────────────────────────────────────────────────────────────────────┘
```

**The engine is in-process.** The SwiftUI layer talks to `Engine` directly and subscribes to its event stream. A future network server (for an iOS client) is just another subscriber to the same stream — the local UI never goes through HTTP.

### Modules

| Module | Responsibility | Depends on |
|---|---|---|
| `KuriCore` | `Item`, `ContentPart`, `ToolCall`, `ToolSpec`, `InferenceEvent`, `Usage`, `ModelRef`, `JSONValue` | — |
| `KuriConfig` | Resolves `~/.kuri`, loads and watches `config.json` / `mcp.json`, resolves secrets from Keychain or environment | Core |
| `KuriStore` | SQLite wrapper, migrations, conversations, turns, items, full-text search, memories | Core |
| `KuriInference` | `InferenceProvider` protocol, SSE parser, one adapter per wire format | Core, Config |
| `KuriTools` | `Tool` protocol, `ToolRegistry`, permission policy, built-in tools | Core, Store |
| `KuriAgent` | `Engine` facade, `TurnRunner` (the agent loop), `InteractionBroker` (clarify/approval), event broadcasting | all of the above |
| `KuriMCP` *(planned)* | MCP client manager on the official Swift SDK; turns MCP tools into `Tool`s | Core, Config, Tools |
| `KuriSandbox` *(planned)* | Container lifecycle on Apple Containerization; `shell` tool | Core, Config, Tools |
| `KuriMarkdown` *(planned)* | Streaming Markdown → SwiftUI renderer on `swift-markdown` | — |

Dependencies point one way: down towards `KuriCore`. Nothing in the package imports SwiftUI.

### Conversation model: items, not messages

A conversation is an ordered list of **items**, close to the Open Responses item model:

| Item | Meaning |
|---|---|
| `message` | A user or assistant message: an array of content parts (text, attachments) |
| `reasoning` | The model's reasoning: readable text plus optional opaque provider data |
| `toolCall` | The model asked to run a tool: call id, tool name, raw JSON arguments |
| `toolResult` | The output for a call id, with an error flag |
| `compaction` | A summary that replaces everything before it when building the next request |

Kuri is **stateless towards providers**: every request carries the history it needs, rebuilt from the database. That keeps behaviour identical across providers (local runtimes don't support server-side state anyway), works offline, and makes switching model mid-conversation trivial. The database is the source of truth.

### A turn

1. The user's message is stored as an item and a `turn` row is opened.
2. `TurnRunner` builds the request: instructions (base prompt, memories, attached folders, date) + items since the last `compaction` + the specs of enabled tools.
3. The provider streams `InferenceEvent`s. Deltas go straight to the UI; completed items are persisted as they arrive.
4. If the model called tools: each call is checked against its permission policy (`allow` / `ask` / `deny`), run, its output capped, and stored as a `toolResult`. Back to step 2.
5. Otherwise the turn closes with its stop reason and token usage.

Guards carried over from Alembic: a round limit per turn, detection of identical repeated calls, a cap on tool output size, and (planned) compaction when the context approaches the model's window, plus fallback models.

**Clarify suspends the turn.** The `clarify` tool asks the user and *waits*: the answer is the tool's return value, so the model continues the same turn. The tool call is already persisted, so a pending question survives a relaunch — a `toolCall` with no matching `toolResult` *is* the pending state.

### Providers and wire formats

| Wire format | Used for |
|---|---|
| `open-responses` | OpenAI, Ollama, LM Studio, vLLM, and anything else speaking the Open Responses spec |
| `anthropic-messages` | Anthropic's API *(planned)* |
| `gemini` | Google's native API *(planned)* |
| `chat-completions` | Legacy fallback for servers that only speak `/v1/chat/completions` *(planned)* |
| `apple-foundation-models` | Apple's on-device model, used for small jobs: titles, summaries, memory review *(planned)* |

Every adapter implements one method — `stream(InferenceRequest) -> AsyncThrowingStream<InferenceEvent>` — and maps its wire format to the shared item model in both directions. No official Swift SDK exists for these providers, so the adapters are hand-written over `URLSession` and a small SSE parser.

### Tools

Every tool implements `Tool`: a spec (name, description, JSON Schema), a default permission, whether it is read-only, and an async `run`.

| Tool | What it does | Default |
|---|---|---|
| `clarify` | Ask the user one or more questions and wait for the answers | allow |
| `tasklist` | Write the current task list (the whole list each call) | allow |
| `memory` | Add, update, remove or list long-term memories | allow |
| `conversation_search` | Full-text search over past conversations | allow |
| `read_file`, `list_files`, `search_files` *(planned)* | Read inside the attached folders | allow |
| `write_file`, `edit_file` *(planned)* | Change files inside the attached folders | ask |
| `shell` *(planned)* | Run a command in the conversation's container | allow (it's sandboxed) |
| MCP tools *(planned)* | Discovered at runtime, named `server__tool` | per `mcp.json`, else ask |

The task list has no table: the current list is the arguments of the latest `tasklist` call.

### MCP (planned)

Built on the official [MCP Swift SDK](https://github.com/modelcontextprotocol/swift-sdk), stdio and Streamable HTTP transports.

- Servers are declared in `mcp.json` using the same `mcpServers` shape as other MCP clients, so existing snippets paste straight in.
- The file is watched: adding, changing or removing a server connects, reconnects or disconnects it without a relaunch.
- Tools are discovered with `tools/list` and refreshed on `notifications/tools/list_changed`. Discovery state lives in memory, not in the database.
- Per-tool policies (`allow` / `ask` / `deny`, with `*` globs) live next to the server in `mcp.json`.

### Sandbox (planned)

One container type, one container per conversation, built on Apple's [Containerization](https://github.com/apple/containerization) package (each container is its own lightweight VM).

- Started lazily on the first `shell` call, stopped after a period of inactivity.
- **The container is disposable; the folders are not.** Attached folders are mounted at `/work/<name>` (or `/work` if there's only one); with no folder attached, a per-conversation scratch folder in `~/.kuri/scratch/` is mounted instead. Edits land directly on disk.
- Network is off by default; it can be turned on per conversation.
- File tools run on the host, but only inside the attached folders, using the same `/work/...` paths the shell sees — one path namespace for the model.
- The image is configurable in `config.json`; once pulled it is cached, so the sandbox works offline.
- Runs in an XPC service inside the app bundle, so a misbehaving VM can't take the app down.
- Not covered by design: macOS-native commands (`xcodebuild`, `open`…). A host-side shell with approval may come later.

### Configuration

Everything lives in `~/.kuri` (override with the `KURI_HOME` environment variable):

```
~/.kuri/
├─ config.json     providers, models, defaults, sandbox settings
├─ mcp.json        MCP servers
├─ kuri.sqlite     conversations, turns, items, memories
├─ blobs/          attachments, content-addressed by SHA-256
└─ scratch/        per-conversation working folders
```

Both config files are **JSON5**: comments, unquoted keys and trailing commas are fine (decoded with Foundation's `JSONDecoder.allowsJSON5`, no extra dependency). Kuri writes a commented template on first launch. The files are the only source of truth for providers, models and MCP servers; nothing about them is copied into the database.

`config.json`:

```json5
{
  // "<provider>/<model>". Everything after the first slash is the model id.
  defaultModel: "ollama/qwen3:8b",

  providers: {
    ollama: {
      format: "open-responses",
      baseURL: "http://localhost:11434/v1",
      models: ["qwen3:8b", { id: "qwen3-coder:30b", contextWindow: 65536 }],
    },
    anthropic: {
      format: "anthropic-messages",
      baseURL: "https://api.anthropic.com/v1",
      apiKey: "keychain:anthropic", // or "env:ANTHROPIC_API_KEY"
      models: ["claude-sonnet-5-5"],
    },
  },
}
```

`mcp.json`:

```json5
{
  mcpServers: {
    github: {
      url: "https://api.githubcopilot.com/mcp/",
      headers: { Authorization: "keychain:github-mcp" },
      tools: { "create_*": "ask", "*": "allow" },
    },
    notes: { command: "uvx", args: ["my-notes-mcp"], enabled: false },
  },
}
```

**Secrets** are references, never values: `keychain:<name>` reads the generic password stored by Kuri under that name, `env:<VAR>` reads an environment variable. A literal string also works, but it then sits in a plain file.

UI preferences (theme, window state, hotkey) are not configuration in this sense; they live in `UserDefaults` like any Mac app's.

### Storage

One SQLite file, opened in WAL mode with foreign keys on, migrated with `PRAGMA user_version`. Accessed through the system `sqlite3` library and a thin wrapper — no ORM. The schema is deliberately small:

```sql
conversations        (id, parent_id, title, model, system_prompt, pinned, archived, created_at, updated_at)
conversation_folders (conversation_id, path, read_only)
turns                (id, conversation_id, model, status, stop_reason, error,
                      input_tokens, output_tokens, reasoning_tokens, cached_tokens, started_at, ended_at)
items                (id, conversation_id, turn_id, seq, kind, role, text, payload, created_at)
items_fts            -- FTS5 over items.text, kept in sync by triggers
memories             (id, content, source, status, supersedes_id, origin_conversation_id, created_at, updated_at)
```

- `items.payload` is the item's JSON; `items.text` is its searchable text, extracted on insert.
- `parent_id` is for forks and, later, sub-agent conversations.
- Things that *don't* need tables: pending clarifications and the task list (derived from items), MCP tool discovery (in memory), usage reports (aggregated from `turns`), attachments (files in `blobs/`, referenced from the payload).

### App shell

- **Main window**: sidebar of conversations, transcript, composer.
- **Menu bar** (`MenuBarExtra`): quick access and a compact chat; the app keeps running in the background with no windows open.
- **Mini panel** *(planned)*: a floating, non-activating `NSPanel` summoned with a global hotkey.
- **Settings**: shows where the config lives, opens it in your editor, and (planned) edits providers and MCP servers. Edits made from the UI rewrite the JSON5 file, so hand-written comments in it are not preserved.
- **Styling**: every control gets its look from custom `ButtonStyle`/`ToggleStyle`/… implementations reading a theme from the environment, so the whole app can be re-skinned in one place. See `Sketches/` for what plain SwiftUI can do.

### Distribution and security

- Distributed outside the Mac App Store: Developer ID signing, Hardened Runtime, notarization.
- **No App Sandbox.** Child processes inherit it, which breaks stdio MCP servers (`npx`, `uvx`) and real shell work. Safety comes from Kuri's own layers instead: the container VM, tools confined to attached folders, and the permission policy.
- Entitlements: `com.apple.security.virtualization` once the sandbox lands.
- Secrets in the Keychain; logs through `os.Logger`.

### Dependencies

| Dependency | Why | When |
|---|---|---|
| Apple frameworks (SwiftUI, AppKit, Foundation, Security, SQLite3, Virtualization) | Everything | Now |
| [modelcontextprotocol/swift-sdk](https://github.com/modelcontextprotocol/swift-sdk) | MCP client | With `KuriMCP` |
| [apple/containerization](https://github.com/apple/containerization) | Sandbox | With `KuriSandbox` |
| [swiftlang/swift-markdown](https://github.com/swiftlang/swift-markdown) | Markdown parsing | With `KuriMarkdown` |

### Later: iOS client

`KuriCore`, `KuriInference` and `KuriAgent` contain nothing Mac-specific. An iOS app can either connect to a Mac running Kuri (a planned `KuriServer` module: HTTP + WebSocket over `Network.framework`, Bonjour discovery, pairing) or run on its own with hosted providers or the on-device model.

---

## Roadmap

1. **Foundations** — domain model, config, storage, Open Responses adapter, agent loop, app shell. *(this draft)*
2. **A usable chat** — streaming Markdown renderer, conversation management, settings, title generation.
3. **More providers** — Anthropic Messages, Gemini, Chat Completions, Apple Foundation Models.
4. **MCP** — client, hot-reload, per-tool policies, approval UI.
5. **Files and sandbox** — folder attachment, file tools, Containerization, `shell`.
6. **Polish** — mini panel and hotkey, theming, compaction, fallback models, memory review.
7. **Beyond** — sub-agents, iOS client.
