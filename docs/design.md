# Kuri's design in detail

The [README](../README.md) gives the overview. This document explains how each part works; [flows.html](flows.html) shows the same parts in motion, [config.md](config.md) lists every configuration key, and [decisions/](decisions/) records why things are the way they are.

## Conversation model: items, not messages

A conversation is an ordered list of **items**, close to the Open Responses item model:

| Item | Meaning |
|---|---|
| `message` | A user or assistant message: an array of content parts (text, attachments) |
| `reasoning` | The model's reasoning: readable text plus optional opaque provider data |
| `toolCall` | The model asked to run a tool: call id, tool name, raw JSON arguments |
| `toolResult` | The output for a call id, with an error flag |
| `compaction` | A summary that stands in for the start of the conversation, up to the item it names |

Kuri is **stateless towards providers**: every request carries the history it needs, rebuilt from the database. That keeps behaviour identical across providers (local runtimes don't support server-side state anyway), works offline, and makes switching model mid-conversation trivial. The database is the source of truth.

## A turn

1. The user's message is stored as an item and a `turn` row is opened.
2. `TurnRunner` builds the request: instructions (base prompt, memories, attached folders, date) + the history (the latest summary, then everything it doesn't cover) + the specs of enabled tools. If that would overflow the model's context, it compacts first.
3. The provider streams `InferenceEvent`s. Deltas go straight to the UI; completed items are persisted as they arrive.
4. If the model called tools: each call is checked against its permission policy (`allow` / `ask` / `deny`), run, its output capped, and stored as a `toolResult`. Back to step 2.
5. Otherwise the turn closes with its stop reason and token usage.

Guards against runaway turns: a round limit per turn, detection of identical repeated calls, and a cap on tool output size. Fallback models are planned.

**Messages sent during a turn are queued.** While a conversation is busy (a turn or a compaction), `Engine.send` queues the message instead of failing. The running turn takes the queue at each step boundary: after a tool round, and when its answer would otherwise end the turn, so the message joins the same turn and the next request includes it. A message that arrives after the turn has ended, or was queued before Stop, starts the next turn as soon as the conversation is free. Queued messages can be removed before delivery; they live in memory only.

**Clarify and approvals suspend the turn.** The `clarify` tool asks the user and *waits*: the answer is the tool's return value, so the model continues the same turn. A tool whose policy is `ask` waits the same way for Allow or Deny. While waiting, the turn's status is `awaiting_input`.

**Turns survive a relaunch.** Nothing extra is stored for a pending question: the tool call is already persisted, and a `toolCall` with no matching `toolResult` in an `awaiting_input` turn *is* the pending state. On launch, `Engine.resumePendingTurns()` re-runs those calls through the normal path, which asks the question (or for approval) again, and the turn carries on. Turns that were mid-stream when Kuri quit can't be resumed safely (a tool might have half-run), so they're marked failed with "Interrupted". **Continue** (`Engine.continueConversation`) starts a turn without a new message, after an interrupted, failed or stopped turn; a call left without a result gets a placeholder result, so the model knows and moves on.

## Compaction

A long conversation is summarized so it keeps fitting in the model's context.

- **When.** Before each request, if it would fill 75% of the model's `contextWindow` (set per model in `config.json`; estimated at about four characters per token). Without a `contextWindow`, only on demand: the toolbar's context meter has a Compact action.
- **What's kept.** The latest exchange stays verbatim: everything from the latest user message on. If that alone is too big, only its tail is kept, cut where it doesn't separate a tool call from its result.
- **How it's stored.** The summary is a `compaction` item appended at the end, naming the last item it covers (`throughItemID`). The next request carries the summary, then every item after that one. Storage stays append-only and the transcript keeps everything; only the model's view shrinks. The next compaction folds the previous summary into the new one.
- **Who writes it.** The `utilityModel` if one is set, otherwise the conversation's model, from a plain-text transcript (tool results truncated) and instructions to keep goals, decisions, facts verbatim, tool outcomes, plan state and open questions.
- **Exact details after the fact.** `conversation_search` with `scope: "this_chat"` searches what a summary replaced.

## Providers

Every adapter implements one method — `stream(InferenceRequest) -> AsyncThrowingStream<InferenceEvent>` — and maps its wire format to the shared item model in both directions. No official Swift SDK exists for these providers, so the adapters are hand-written over `URLSession` and a small SSE parser.

## Tools

**Policies.** `allow` runs the call, `ask` shows an approval panel first, `deny` hides the tool from the model entirely. Rules come from `config.json` (`tools`, by the name the model sees, for any tool) and `mcp.json` (`tools` inside a server, by the server's own names). An exact name beats a `*` glob, a longer glob beats a shorter one, and `config.json` wins over `mcp.json` on the same name.

**Built-in tools in detail.**

- `clarify` blocks the turn and shows a panel with the questions (and suggested answers, if the model gave any). The answers come back as the tool's result.
- `tasklist` has no table: the current plan is the arguments of the latest successful call. The app pins it above the composer while it has open tasks.
- `memory` entries appear in every conversation's instructions with a short id (`m12`), so the model edits them directly. All changes in a call land atomically, and the call fails if the entries would exceed 4,000 characters in total, so the model has to make room in the same call. The tool's description spells out what *not* to save. You can view and edit memories in Settings.
- `conversation_search` matches any of the words (as prefixes, ranked by how many match), groups hits by conversation, and returns each hit with the messages before and after it. By default it searches the other conversations; `scope: "this_chat"` searches only the part of the current conversation that a summary replaced, to recover exact details after compaction. (If nothing was summarized yet, it searches the other conversations instead and says so.)

**No file tools.** The shell lists, reads, searches and writes files; separate `read_file`/`write_file`/`edit_file` tools would only duplicate it. One tool, one path namespace, one place to sandbox.

**No artifacts.** A file the model creates is just a file, in an attached folder or in the conversation's scratch folder. There is no separate concept of generated documents to store, list or preview.

## MCP

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

## Sandbox

`KuriSandbox` gives each conversation a Linux container on Apple's [Containerization](https://github.com/apple/containerization) package. Each container is its own lightweight VM, run by Virtualization.framework in a separate system process, so a misbehaving VM can't take the app down; there's no extra XPC service to maintain.

- **One container per conversation, one kind of container.** Started on the first `shell` call (about half a second, VM boot included), reused for later commands (tens of milliseconds each), stopped after `idleMinutes` without one (10 by default), and recreated when the conversation's folders change.
- **The container is disposable; the folders are not.** One attached folder is mounted at `/work`, several at `/work/<name>`; with none, a per-conversation scratch folder (`~/.config/kuri/scratch/<id>`) is. Read-only folders are mounted read-only. Edits land directly on disk; anything else (installed packages, files outside `/work`) disappears with the container.
- **No network.** Containers get no network interface at all.
- **The shell is the only way the model touches files.** Commands run with `/bin/sh -lc` from `/work`, with a timeout (120 s by default, 900 at most). Output keeps its start and end when it's long; stopping the turn kills the command.
- **The image** is `python:3-slim` by default (Debian with bash, coreutils and Python), configurable as `sandbox.image`. Since there's no network, what the image ships with is what the model can use.
- **Setup, once** (Settings › Sandbox). It downloads:
  - a Linux kernel: Kata Containers publishes its container-tuned kernel only inside its release tarball (about 680 MB), so Kuri downloads it once and keeps just the kernel;
  - Apple's init filesystem (`ghcr.io/apple/containerization/vminit`, matching the package version);
  - the container image, unpacked once into a snapshot that each container clones (APFS copy-on-write).
  After that the sandbox works offline. Everything lives in `~/.config/kuri/sandbox`: about 0.8 GB with the default image, mostly image layers, Apple's init filesystem and the unpacked snapshot (the kernel itself is 18 MB). The `shell` tool only appears once setup is done.
- **The model is told where things are:** its instructions say which folder of the user's is mounted where (or that `/work` is a scratch folder).
- **Testing.** Starting a VM needs the `com.apple.security.virtualization` entitlement on the running executable, which `swift test` can't have; the package tests cover the logic, and real VMs are exercised by a signed executable and by the app.
- **Not covered by design:** macOS-native commands (`xcodebuild`, `open`…). A host-side shell with approval may come later.

## Configuration

Everything lives in `~/.config/kuri`. The location resolves in this order: the `KURI_HOME` environment variable, then `$XDG_CONFIG_HOME/kuri`, then `~/.config/kuri`.

```
~/.config/kuri/
├─ config.json     providers, models, defaults, tool policies, sandbox settings
├─ mcp.json        MCP servers
├─ kuri.sqlite     conversations, turns, items, memories
├─ blobs/          attachments, content-addressed by SHA-256
├─ scratch/        per-conversation working folders (mounted when no folder is attached)
└─ sandbox/        Linux kernel, images and snapshots for the sandbox
```

Every key is documented in [config.md](config.md). Both config files are **JSON5**: comments, unquoted keys and trailing commas are fine (decoded with Foundation's `JSONDecoder.allowsJSON5`, no extra dependency). Kuri writes a commented template on first launch. The files are the only source of truth for providers, models and MCP servers; nothing about them is copied into the database.

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

  // The Linux sandbox. All optional; these are the defaults.
  // kernel: "/path/to/vmlinux" uses a kernel you already have instead of downloading one.
  sandbox: { image: "docker.io/library/python:3-slim", cpus: 4, memoryMiB: 2048, idleMinutes: 10 },
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

## Storage

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

## App shell

- **Main window**: sidebar of conversations, transcript, composer. The toolbar shows the model and an estimated context meter (with Compact); a turn that didn't complete ends with a Continue bar; pending questions and approvals sit above the composer and come back after a relaunch.
- **Menu bar** (`MenuBarExtra`): quick access and a compact chat; the app keeps running in the background with no windows open.
- **Mini panel** *(planned)*: a floating, non-activating `NSPanel` summoned with a global hotkey.
- **Settings**: *General* shows where the config lives; *Models* registers models per provider (with discovery) and sets the default; *Tools* lists built-in tools and MCP servers with their state and policies; *Memory* views and edits what Kuri remembers. Providers and MCP servers are still edited in their files.
- **Styling**: every control gets its look from custom `ButtonStyle`/`ToggleStyle`/… implementations reading a theme from the environment, so the whole app can be re-skinned in one place. See `Sketches/` for what plain SwiftUI can do.

## Distribution and security

- Distributed outside the Mac App Store: Developer ID signing, Hardened Runtime, notarization.
- **No App Sandbox.** Child processes inherit it, which breaks stdio MCP servers (`npx`, `uvx`) and real shell work. Safety comes from Kuri's own layers instead: the container VM (which only sees the attached folders) and the permission policy.
- Entitlements: `com.apple.security.virtualization` (`App/Kuri.entitlements`), for the sandbox's VMs.
- Secrets in the Keychain; logs through `os.Logger`.

## Testing

- `swift test` in `Packages/KuriKit` runs the unit and integration tests, including MCP servers written as Python fixtures (standard library only) and engine tests against a stubbed Open Responses endpoint.
- Live tests run real turns against a model and are skipped unless `KURI_LIVE_MODEL` names one (`KURI_LIVE_MODEL=ollama/qwen3.5:2b swift test --filter LiveTests`). Small models aren't deterministic, so they assert on what the plumbing guarantees and print transcripts.
- Real sandbox VMs need the virtualization entitlement on the running executable, which `swift test` can't have; they're exercised from a signed executable (see [CLAUDE.md](../CLAUDE.md)).

## Later: iOS client

`KuriCore`, `KuriInference` and `KuriAgent` contain nothing Mac-specific. An iOS app can either connect to a Mac running Kuri (a planned `KuriServer` module: HTTP + WebSocket over `Network.framework`, Bonjour discovery, pairing) or run on its own with hosted providers or the on-device model.
