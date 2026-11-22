# Kuri

A native macOS app for working with language models — local or hosted — that can chat, think, and act on your files from a sandbox.

Kuri is a single app that is both the engine and the interface: no server to deploy, no database service, no Docker. It runs offline with local models, talks to any hosted provider when you want it to, discovers MCP servers at runtime, and runs the model's commands inside a lightweight Linux VM.

> Status: early. Working: the Open Responses adapter, the agent loop, the built-in tools, MCP servers with runtime discovery, durable turns, compaction, and a basic app. Sections marked *(planned)* describe what comes next.

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
│  │  ├─ KuriConfig/      ~/.config/kuri paths, JSON5 config, secrets
│  │  ├─ KuriStore/       SQLite storage
│  │  ├─ KuriInference/   Provider protocol, SSE, wire-format adapters
│  │  ├─ KuriTools/       Tool protocol, registry, permissions, built-in tools
│  │  ├─ KuriMCP/         MCP servers: connections, discovery, hot-reload
│  │  └─ KuriAgent/       The engine: turn loop, interaction broker, events
│  └─ Tests/
├─ docs/flows.html        Sequence diagrams of every flow, and the event reference
└─ Sketches/              UI experiments (not part of the build)
```

Build the app from Xcode (`Kuri` scheme). The package builds and tests on its own:

```bash
cd Packages/KuriKit && swift test
```

Live tests run real turns against a model and are skipped unless you name one:

```bash
cd Packages/KuriKit && KURI_LIVE_MODEL=ollama/qwen3.5:2b swift test --filter LiveTests
```

---

## Architecture

### Overview

```
┌───────────────────────────────── Kuri.app ─────────────────────────────────┐
│                                                                            │
│  App (SwiftUI)   main window · mini panel · menu bar · settings            │
│        │  observes EngineEvents, calls Engine methods                      │
│        ▼                                                                   │
│  KuriAgent       Engine (actor) ── TurnRunner ── InteractionBroker         │
│        │                                                                   │
│        ├──────────────┬──────────────┬─────────────┬─────────────┐         │
│        ▼              ▼              ▼             ▼             ▼         │
│  KuriInference    KuriMCP        KuriTools     KuriStore     KuriConfig    │
│  adapters         MCP servers    registry,     SQLite file   JSON5 files,  │
│  (HTTP + SSE)     → tools        built-ins                   Keychain      │
│        └──────────────┴── KuriCore (domain types) ─┴─────────────┘         │
│                                                                            │
│  SandboxService.xpc  (planned) Containerization, isolated from the app     │
└────────────────────────────────────────────────────────────────────────────┘
```

**The engine is in-process.** The SwiftUI layer talks to `Engine` directly and subscribes to its event stream. A future network server (for an iOS client) is just another subscriber to the same stream — the local UI never goes through HTTP.

**Flows.** [`docs/flows.html`](docs/flows.html) documents every flow as a sequence diagram: startup and quit, a turn, tool rounds, approval, clarify, cancellation, resuming after a relaunch, Continue, compaction, MCP connection, calls, runtime tool changes and crashes, config hot-reload, model registration and memory edits, plus a reference of every engine event and external protocol. It's a single self-contained page (open it in a browser); each diagram is data in the page, rendered to SVG by a small script, so updating a flow means editing a few lines. Keep it in step with the code when a flow changes.

### Modules

| Module | Responsibility | Depends on |
|---|---|---|
| `KuriCore` | `Item`, `ContentPart`, `ToolCall`, `ToolSpec`, `InferenceEvent`, `Usage`, `ModelRef`, `JSONValue` | — |
| `KuriConfig` | Resolves `~/.config/kuri`, loads and watches `config.json` / `mcp.json`, edits `config.json` for the UI, resolves secrets from Keychain or environment | Core |
| `KuriStore` | SQLite wrapper, migrations, conversations, turns, items, full-text search, memories | Core |
| `KuriInference` | `InferenceProvider` protocol, SSE parser, one adapter per wire format, model discovery | Core, Config |
| `KuriTools` | `Tool` protocol, `ToolRegistry`, permission policy, built-in tools | Core, Store |
| `KuriAgent` | `Engine` facade, `TurnRunner` (the agent loop), `InteractionBroker` (clarify/approval), event broadcasting | all of the above |
| `KuriMCP` | MCP connections on the official Swift SDK: config diffing, discovery, process transport, MCP tools as `Tool`s | Core, Config, Tools |
| `KuriSandbox` *(planned)* | Container lifecycle on Apple Containerization; the `shell` tool | Core, Config, Tools |
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
| `compaction` | A summary that stands in for the start of the conversation, up to the item it names |

Kuri is **stateless towards providers**: every request carries the history it needs, rebuilt from the database. That keeps behaviour identical across providers (local runtimes don't support server-side state anyway), works offline, and makes switching model mid-conversation trivial. The database is the source of truth.

### A turn

1. The user's message is stored as an item and a `turn` row is opened.
2. `TurnRunner` builds the request: instructions (base prompt, memories, attached folders, date) + the history (the latest summary, then everything it doesn't cover) + the specs of enabled tools. If that would overflow the model's context, it compacts first.
3. The provider streams `InferenceEvent`s. Deltas go straight to the UI; completed items are persisted as they arrive.
4. If the model called tools: each call is checked against its permission policy (`allow` / `ask` / `deny`), run, its output capped, and stored as a `toolResult`. Back to step 2.
5. Otherwise the turn closes with its stop reason and token usage.

Guards against runaway turns: a round limit per turn, detection of identical repeated calls, and a cap on tool output size. Fallback models are planned.

**Clarify and approvals suspend the turn.** The `clarify` tool asks the user and *waits*: the answer is the tool's return value, so the model continues the same turn. A tool whose policy is `ask` waits the same way for Allow or Deny. While waiting, the turn's status is `awaiting_input`.

**Turns survive a relaunch.** Nothing extra is stored for a pending question: the tool call is already persisted, and a `toolCall` with no matching `toolResult` in an `awaiting_input` turn *is* the pending state. On launch, `Engine.resumePendingTurns()` re-runs those calls through the normal path, which asks the question (or for approval) again, and the turn carries on. Turns that were mid-stream when Kuri quit can't be resumed safely (a tool might have half-run), so they're marked failed with "Interrupted". **Continue** (`Engine.continueConversation`) starts a turn without a new message, after an interrupted, failed or stopped turn; a call left without a result gets a placeholder result, so the model knows and moves on.

### Compaction

A long conversation is summarized so it keeps fitting in the model's context.

- **When.** Before each request, if it would fill 75% of the model's `contextWindow` (set per model in `config.json`; estimated at about four characters per token). Without a `contextWindow`, only on demand: the toolbar's context meter has a Compact action.
- **What's kept.** The latest exchange stays verbatim: everything from the latest user message on. If that alone is too big, only its tail is kept, cut where it doesn't separate a tool call from its result.
- **How it's stored.** The summary is a `compaction` item appended at the end, naming the last item it covers (`throughItemID`). The next request carries the summary, then every item after that one. Storage stays append-only and the transcript keeps everything; only the model's view shrinks. The next compaction folds the previous summary into the new one.
- **Who writes it.** The `utilityModel` if one is set, otherwise the conversation's model, from a plain-text transcript (tool results truncated) and instructions to keep goals, decisions, facts verbatim, tool outcomes, plan state and open questions.
- **Exact details after the fact.** `conversation_search` with `scope: "this_chat"` searches what a summary replaced.

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

Every tool implements `Tool`: a spec (name, description, JSON Schema), a default policy, whether it is read-only, and an async `run`. The `ToolRegistry` holds them all, built-in and discovered alike, each tagged with its source (`builtIn` or `mcp(server:)`), and decides which ones the model sees.

| Tool | What it does | Default |
|---|---|---|
| `clarify` | Ask the user one or more questions and wait for the answers | allow |
| `tasklist` | Write the current plan (the whole list each call) | allow |
| `memory` | Add, update or remove long-term memories, in one batched call | allow |
| `conversation_search` | Full-text search over past conversations, or this one | allow |
| `shell` *(planned)* | Run a command in the conversation's container | allow (it's sandboxed) |
| MCP tools | Discovered at runtime, named `<server>__<tool>` | allow if the server marks them read-only, else ask |

**Policies.** `allow` runs the call, `ask` shows an approval panel first, `deny` hides the tool from the model entirely. Rules come from `config.json` (`tools`, by the name the model sees, for any tool) and `mcp.json` (`tools` inside a server, by the server's own names). An exact name beats a `*` glob, a longer glob beats a shorter one, and `config.json` wins over `mcp.json` on the same name.

**Built-in tools in detail.**

- `clarify` blocks the turn and shows a panel with the questions (and suggested answers, if the model gave any). The answers come back as the tool's result.
- `tasklist` has no table: the current plan is the arguments of the latest successful call. The app pins it above the composer while it has open tasks.
- `memory` entries appear in every conversation's instructions with a short id (`m12`), so the model edits them directly. All changes in a call land atomically, and the call fails if the entries would exceed 4,000 characters in total, so the model has to make room in the same call. The tool's description spells out what *not* to save. You can view and edit memories in Settings.
- `conversation_search` matches any of the words (as prefixes, ranked by how many match), groups hits by conversation, and returns each hit with the messages before and after it. By default it searches the other conversations; `scope: "this_chat"` searches only the part of the current conversation that a summary replaced, to recover exact details after compaction. (If nothing was summarized yet, it searches the other conversations instead and says so.)

**No file tools.** The shell lists, reads, searches and writes files; separate `read_file`/`write_file`/`edit_file` tools would only duplicate it. One tool, one path namespace, one place to sandbox.

**No artifacts.** A file the model creates is just a file, in an attached folder or in the conversation's scratch folder. There is no separate concept of generated documents to store, list or preview.

### MCP

`KuriMCP` connects to the servers in `mcp.json` with the official [MCP Swift SDK](https://github.com/modelcontextprotocol/swift-sdk), over stdio or Streamable HTTP.

- **Same file format as other MCP clients.** Servers are declared under `mcpServers`, so existing snippets paste straight in. Kuri adds two optional keys per server: `enabled` and `tools` (policies).
- **Hot-reload.** The config folder is watched; `MCPManager.apply` diffs the new file against what's running. New or changed servers (re)connect, removed or disabled ones disconnect, untouched ones are left alone.
- **Runtime discovery.** Tools come from `tools/list` (following pagination) and are refreshed on `notifications/tools/list_changed`. They join the registry as `<server>__<tool>` (sanitized to `[A-Za-z0-9_-]`, at most 64 characters). Discovery state lives in memory, not in the database.
- **Default policies from the server.** A tool annotated `readOnlyHint` runs without asking; any other asks first. `config.json` and `mcp.json` rules override this.
- **stdio servers** are launched by Kuri's own `ProcessTransport`, which owns the child process and is driven by readability callbacks, so an idle server costs nothing. (The SDK's stdio transport takes file descriptors and polls them.) Their stderr is kept as a short log shown in Settings, and a server that exits is marked as failed and its tools removed until it's reconnected.
- **`PATH`.** Apps launched from Finder get a minimal `PATH`, so `npx` or `uvx` wouldn't be found. Kuri asks the user's login shell for its `PATH` once and uses it for every stdio server.
- **Remote servers** get their `headers` (secret references resolved) on every request. OAuth isn't supported yet.
- **Cancellation.** Stopping a turn cancels an in-flight call on the server too (`notifications/cancelled`).

Settings › Tools lists every server with its state, the server's own name and version, its tools and their policies, the log, and a Reconnect button.

### Sandbox (planned)

One container type, one container per conversation, built on Apple's [Containerization](https://github.com/apple/containerization) package (each container is its own lightweight VM).

- Started lazily on the first `shell` call, stopped after a period of inactivity.
- **The container is disposable; the folders are not.** Attached folders are mounted at `/work/<name>` (or `/work` if there's only one); with no folder attached, a per-conversation scratch folder in `~/.config/kuri/scratch/` is mounted instead. Edits land directly on disk.
- Network is off by default; it can be turned on per conversation.
- The shell is the only way the model touches files: listing, reading, searching and editing all happen in the container, on the mounted folders.
- The image is configurable in `config.json`; once pulled it is cached, so the sandbox works offline.
- Runs in an XPC service inside the app bundle, so a misbehaving VM can't take the app down.
- Not covered by design: macOS-native commands (`xcodebuild`, `open`…). A host-side shell with approval may come later.

### Configuration

Everything lives in `~/.config/kuri`. The location resolves in this order: the `KURI_HOME` environment variable, then `$XDG_CONFIG_HOME/kuri`, then `~/.config/kuri`.

```
~/.config/kuri/
├─ config.json     providers, models, defaults, tool policies, sandbox settings
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
  defaultModel: "ollama/qwen3.5:2b",

  providers: {
    ollama: {
      format: "open-responses",
      baseURL: "http://localhost:11434/v1",
      models: ["qwen3.5:2b", { id: "qwen3.5:9b", contextWindow: 65536 }],
    },
    anthropic: {
      format: "anthropic-messages",
      baseURL: "https://api.anthropic.com/v1",
      apiKey: "keychain:anthropic", // or "env:ANTHROPIC_API_KEY"
      models: ["claude-sonnet-5-5"],
    },
  },

  // Tool policies by the name the model sees; "*" globs work.
  tools: { memory: "deny", "github__*": "ask" },
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

**Models.** Each provider lists its models under `models`, as bare ids or objects with optional `name`, `contextWindow`, `maxOutputTokens`, `reasoningEffort` and `fallbacks`. Two ways to fill that list without typing:

- **Settings › Models** registers models per provider. The id field is a combobox pre-filled with what the provider serves (`GET <baseURL>/models`, available for every OpenAI-style server: Ollama, LM Studio, vLLM, OpenAI, OpenRouter…). You can still type any id. Removing a model and picking the default model live there too.
- **`discoverModels: true`** on a provider makes every model it serves pickable without registering it. Handy for a local Ollama.

When the app changes `config.json`, `ConfigEditor` edits it as a generic JSON tree, so keys Kuri doesn't know survive. It checks that the result still loads, then writes it back as tidy JSON5 with a stable key order. Hand-written comments and formatting are not kept; the file's header says so.

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
- Things that *don't* need tables: pending questions and approvals and the task list (derived from items), MCP tool discovery (in memory), usage reports (aggregated from `turns`), attachments (files in `blobs/`, referenced from the payload).

### App shell

- **Main window**: sidebar of conversations, transcript, composer. The toolbar shows the model and an estimated context meter (with Compact); a turn that didn't complete ends with a Continue bar; pending questions and approvals sit above the composer and come back after a relaunch.
- **Menu bar** (`MenuBarExtra`): quick access and a compact chat; the app keeps running in the background with no windows open.
- **Mini panel** *(planned)*: a floating, non-activating `NSPanel` summoned with a global hotkey.
- **Settings**: *General* shows where the config lives; *Models* registers models per provider (with discovery) and sets the default; *Tools* lists built-in tools and MCP servers with their state and policies; *Memory* views and edits what Kuri remembers. Providers and MCP servers are still edited in their files.
- **Styling**: every control gets its look from custom `ButtonStyle`/`ToggleStyle`/… implementations reading a theme from the environment, so the whole app can be re-skinned in one place. See `Sketches/` for what plain SwiftUI can do.

### Distribution and security

- Distributed outside the Mac App Store: Developer ID signing, Hardened Runtime, notarization.
- **No App Sandbox.** Child processes inherit it, which breaks stdio MCP servers (`npx`, `uvx`) and real shell work. Safety comes from Kuri's own layers instead: the container VM (which only sees the attached folders) and the permission policy.
- Entitlements: `com.apple.security.virtualization` once the sandbox lands.
- Secrets in the Keychain; logs through `os.Logger`.

### Dependencies

| Dependency | Why | When |
|---|---|---|
| Apple frameworks (SwiftUI, AppKit, Foundation, Security, SQLite3, Virtualization) | Everything | Now |
| [modelcontextprotocol/swift-sdk](https://github.com/modelcontextprotocol/swift-sdk) | MCP client | Now |
| [apple/swift-log](https://github.com/apple/swift-log) | The SDK's logging API, which a custom transport has to implement | Now |
| [apple/containerization](https://github.com/apple/containerization) | Sandbox | With `KuriSandbox` |
| [swiftlang/swift-markdown](https://github.com/swiftlang/swift-markdown) | Markdown parsing | With `KuriMarkdown` |

The MCP SDK brings in, transitively, `apple/swift-system`, `apple/swift-log` and `mattt/eventsource` (SSE parsing for its HTTP transport); those are what end up linked into Kuri. SwiftPM also fetches `apple/swift-nio` and friends, used only by the SDK's own sample executables.

### Later: iOS client

`KuriCore`, `KuriInference` and `KuriAgent` contain nothing Mac-specific. An iOS app can either connect to a Mac running Kuri (a planned `KuriServer` module: HTTP + WebSocket over `Network.framework`, Bonjour discovery, pairing) or run on its own with hosted providers or the on-device model.

---

## Roadmap

Done: **foundations** — domain model, config, storage, Open Responses adapter, agent loop, app shell.

The core, in order:

1. **Built-in tools** — `clarify`, `tasklist`, `memory`, `conversation_search`, complete end to end, UI included. *(done)*
2. **MCP** — configurable servers with runtime discovery, hot-reload, per-tool policies, approval UI. *(done)*
3. **Durable turns and compaction** — resume pending questions and approvals after a relaunch; automatic and on-demand compaction. *(done)*
4. **Sandbox** — folder attachment, Containerization, the `shell` tool.

Then embellishments, in no particular order: **message queue** (type while a turn runs: the message joins the running turn at its next step, after the current tool round, or waits for the next turn if it ends first), generated titles, streaming Markdown renderer, UI polish and theming, mini panel and hotkey, more providers (Anthropic Messages, Gemini, Chat Completions, Apple Foundation Models), fallback models, memory review, sub-agents, iOS client.
