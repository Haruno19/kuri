# Kuri's design in detail

The [README](../README.md) gives the overview. This document explains how each part works; [flows.html](flows.html) shows the same parts in motion, [config.md](config.md) lists every configuration key, and [decisions/](decisions/) records why things are the way they are.

## Conversation model: items, not messages

A conversation is an ordered list of **items**, close to the Open Responses item model:

| Item | Meaning |
|---|---|
| `message` | A user or assistant message: its text (stored as Open Responses content parts) |
| `reasoning` | The model's reasoning: readable text plus optional opaque provider data |
| `toolCall` | The model asked to run a tool: call id, tool name, raw JSON arguments |
| `toolResult` | The output for a call id, with an error flag |
| `compaction` | A summary that stands in for the start of the conversation, up to the item it names |

Kuri is **stateless towards providers**: every request carries the history it needs, rebuilt from the database. That keeps behaviour identical across providers (local runtimes don't support server-side state anyway), works offline, and makes switching model mid-conversation trivial. The database is the source of truth.

## A turn

1. The user's message is stored as an item and a `turn` row is opened.
2. `TurnRunner` builds the request: instructions (base prompt, memories, attached folders, date) + the history (the latest summary, then everything it doesn't cover) + the specs of enabled tools. If that would overflow the model's context, it compacts first.
3. The provider streams `InferenceEvent`s. Deltas go straight to the UI; completed items are persisted as they arrive.
4. If the model called tools: each call is checked against its permission policy (`allow` / `ask` / `deny`), run, its output capped, and stored as a `toolResult`. Consecutive calls to read-only tools that run without asking go concurrently; anything that may change something, or needs the user, runs alone. Results are stored in call order either way. Back to step 2.
5. Otherwise the turn closes with its stop reason and token usage.

Guards against runaway turns: a round limit per turn, detection of identical repeated calls, and a cap on tool output size.

**Fallback models.** A model can list `fallbacks` in `config.json`. When a request fails before the model produced anything, the round is sent again to the next fallback, with that model's provider, settings and instructions (no tools mentioned if it can't use them), and `.modelFallback` tells the app which model took over and why. The fallback keeps the rest of the turn; the next turn starts with the conversation's model again. A request that fails after storing output isn't retried, since that would store it twice, and Stop never falls back. Only the conversation's model has fallbacks: titles and summaries don't.

**Titles.** A conversation starts with a provisional title, the first line of its first message. After its first completed turn, if `generateTitles` is on and the title is still the provisional one, the utility model (or the conversation's model) writes a 2-to-6-word title from the first exchange, in the background; labels, quotes and trailing punctuation are cleaned off. A title the user changed meanwhile is left alone, a failure keeps the provisional one, and quitting cancels any title still being written.

**Messages sent during a turn are queued.** While a conversation is busy (a turn or a compaction), `Engine.send` queues the message instead of failing. The running turn takes the queue at each step boundary: after a tool round, and when its answer would otherwise end the turn, so the message joins the same turn and the next request includes it. A message that arrives after the turn has ended, or was queued before Stop, starts the next turn as soon as the conversation is free. Queued messages can be removed before delivery; they live in memory only.

**Clarify and approvals suspend the turn.** The `clarify` tool asks the user and *waits*: the answer is the tool's return value, so the model continues the same turn. A tool whose policy is `ask` waits the same way for Allow or Deny. While waiting, the turn's status is `awaiting_input`.

**Turns survive a relaunch.** Nothing extra is stored for a pending question: the tool call is already persisted, and a `toolCall` with no matching `toolResult` in an `awaiting_input` turn *is* the pending state. On launch, `Engine.resumePendingTurns()` re-runs those calls through the normal path, which asks the question (or for approval) again, and the turn carries on. Turns that were mid-stream when Kuri quit can't be resumed safely (a tool might have half-run), so they're marked failed with "Interrupted". **Continue** (`Engine.continueConversation`) starts a turn without a new message, after an interrupted, failed or stopped turn; a call left without a result gets a placeholder result, so the model knows and moves on. **Retry** (`Engine.retry`) answers the last user message again: everything after it is deleted (the one exception to append-only items, [decision 0016](decisions/0016-retry-replaces-the-answer.md)) and a new turn starts from it.

**When a provider stops answering**, connection failures are reported as the provider being unreachable, naming its endpoint and whether it went away mid-reply, rather than in URLSession's networking terms: most providers are local servers.

## Compaction

A long conversation is summarized so it keeps fitting in the model's context.

- **When.** Before each request, if it would fill `compactAt` (75% by default, set in Settings › General or `config.json`) of the model's `contextWindow` (set per model in `config.json`; estimated at about four characters per token). Without a `contextWindow`, only on demand: the toolbar's context meter has a Compact action.
- **What's kept.** The latest exchange stays verbatim: everything from the latest user message on. If that alone is too big (more than two thirds of `compactAt`, so the next request doesn't compact again), only its tail is kept, cut where it doesn't separate a tool call from its result.
- **How it's stored.** The summary is a `compaction` item appended at the end, naming the last item it covers (`throughItemID`). The next request carries the summary, then every item after that one. Storage stays append-only and the transcript keeps everything; only the model's view shrinks. The next compaction folds the previous summary into the new one.
- **Who writes it.** The `utilityModel` if one is set, otherwise the conversation's model, from a plain-text transcript (tool results truncated) and instructions to keep goals, decisions, facts verbatim, tool outcomes, plan state and open questions.
- **Exact details after the fact.** `conversation_search` with `scope: "this_chat"` searches what a summary replaced.

## Providers

`open-responses` covers every OpenAI-style server.

`anthropic-messages` speaks Anthropic's Messages API (and the servers that copy it, Ollama among them). Items become alternating user and assistant messages of content blocks: consecutive items on one side merge, tool results lead their message, a result whose call was summarized away is left out, and a conversation that ends on the assistant's side gets a closing "Continue." (current models refuse prefills). Every request turns on adaptive thinking with summaries and asks for automatic prompt caching, which pays off because Kuri resends the whole conversation every round; request bodies are encoded with sorted keys so the same history is always the same bytes. Thinking comes back as `reasoning` items whose opaque state is the block's signature (or the whole block, when redacted). A signature is only valid with the exact history it was produced from, so Kuri replays thinking only within the current exchange, never from before a compaction, and asks the API to drop rather than refuse any block that no longer matches (see [decision 0014](decisions/0014-anthropic-thinking-replay.md)).

`apple-foundation-models` runs Apple's on-device model through the FoundationModels framework: each request becomes a fresh `LanguageModelSession` over a transcript rebuilt from the items (user-side and assistant-side text; tool calls and results from earlier turns with other models are described in words), and the reply streams back as text deltas. That model gets no tools: its 4,096-token context would be mostly spent on Kuri's tool definitions, and FoundationModels runs tools inside its own session, outside Kuri's policies and persistence (see [decision 0013](decisions/0013-apple-model-text-only.md)). A provider says whether it supports tools; when it doesn't, requests carry none and the instructions don't mention any.

Every adapter implements one method — `stream(InferenceRequest) -> AsyncThrowingStream<InferenceEvent>` — and maps its wire format to the shared item model in both directions. No official Swift SDK exists for these providers, so the adapters are hand-written over `URLSession` and a small SSE parser. A stream may stay silent for up to ten minutes before it fails: local servers queue requests and can take minutes over a long prompt before the first byte. Error responses show the server's own message when it sends one in the usual `{"error": {"message"}}` shape.

## Tools

**Policies.** `allow` runs the call, `ask` shows an approval panel first, `deny` hides the tool from the model entirely. Rules come from `config.json` (`tools`, by the name the model sees, for any tool) and `mcp.json` (`tools` inside a server, by the server's own names). An exact name beats a `*` glob, a longer glob beats a shorter one, and `config.json` wins over `mcp.json` on the same name.

**Built-in tools in detail.**

- `clarify` blocks the turn and shows a panel with the questions (and suggested answers, if the model gave any). The answers come back as the tool's result.
- `tasklist` has no table: the current plan is the arguments of the latest successful call. The app pins it above the composer while it has open tasks (or shows it in the inspector when that's open). There it takes room only for its folded height: unfolded, it floats up over the transcript, and when the inspector opens or closes it goes or comes back with a short fade once the slide is over (`toggleInspector()`, the one way the inspector is shown or hidden), so the transcript is never laid out again at every frame. The user's own edits, made in the inspector, are stored the same way: a `tasklist` call and its result with an id starting `kuri_user_tasklist_`, delivered at the next step boundary when a turn is running ([decision 0021](decisions/0021-inspector.md)).
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
- **The image** is Kuri's own by default, `ghcr.io/haruno19/kuri-sandbox` ([decision 0022](decisions/0022-kuri-sandbox-image.md)): `python:3-slim` (Debian with bash, coreutils and Python) plus poppler-utils, pandoc, ImageMagick, ripgrep, jq, git and sqlite3, and the Python libraries pypdf, pdfplumber, pandas, openpyxl, python-docx, Pillow and matplotlib. Since there's no network, what the image ships with is what the model can use; with Kuri's image its instructions say what's there. `Sandbox/Dockerfile` defines it, `.github/workflows/sandbox-image.yml` builds it for arm64 and publishes it to GitHub's container registry when `Sandbox/` changes, tagged with `Sandbox/VERSION`; `SandboxSettings.kuriImage` pins that tag, and a test keeps the two in step. Settings › Sandbox also offers plain `python:3-slim`, or any other image as `sandbox.image`.
- **Setup, once** (Settings › Sandbox). It downloads:
  - a Linux kernel: Kata Containers publishes its container-tuned kernel only inside its release tarball (about 680 MB), so Kuri downloads it once and keeps just the kernel;
  - Apple's init filesystem (`ghcr.io/apple/containerization/vminit`, matching the package version);
  - the container image, unpacked once into a snapshot that each container clones (APFS copy-on-write).
  After that the sandbox works offline. Everything lives in `~/.config/kuri/sandbox`: about 0.8 GB with `python:3-slim` and an estimated 1.6 GB with Kuri's image (a 254 MB download against 45 MB), mostly image layers, Apple's init filesystem and the unpacked snapshot (the kernel itself is 18 MB). The `shell` tool only appears once setup is done.
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
  sandbox: { image: "ghcr.io/haruno19/kuri-sandbox:1", cpus: 4, memoryMiB: 2048, idleMinutes: 10 },
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

- **Settings › Models** registers models per provider. The id field is a combobox pre-filled with what the provider serves (`GET <baseURL>/models`, available for every OpenAI-style server: Ollama, LM Studio, vLLM, OpenAI, OpenRouter…). You can still type any id. Removing a model, picking the default model and saving the provider's API key (in the Keychain) live there too.
- **`discoverModels: true`** on a provider makes every model it serves pickable without registering it. Handy for a local Ollama.

When the app changes `config.json`, `ConfigEditor` edits it as a generic JSON tree, so keys Kuri doesn't know survive. It checks that the result still loads, then writes it back as tidy JSON5 with a stable key order. Hand-written comments and formatting are not kept; the file's header says so.

**Secrets** are references, never values: `keychain:<name>` reads the generic password stored under that name (Settings › Models saves a provider's API key there and writes the reference; the key is never shown again), `env:<VAR>` reads an environment variable. A literal string also works, but it then sits in a plain file.

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
- Things that *don't* need tables: pending questions and approvals and the task list (derived from items), MCP tool discovery (in memory), usage reports (aggregated from `turns`).

## App shell

- **Main window**: following [ui.md](ui.md): a collapsible native sidebar (New chat as the filled primary button, Settings outlined below it, then the conversations, renamed in place from the context menu, a double-click or Return), the transcript, and a composer holding the folder button, the estimated context meter (with Compact), the model picker and send/stop. Each finished answer ends with a dim status line (when it ended, its turn's tokens, split into in and out on hover; Retry on the latest); a turn that didn't complete ends with a Continue bar; pending questions and approvals sit above the composer and come back after a relaunch. The new chat page has a pixel meadow along its bottom edge, a procedural scene drawn as a bitmap in a layer (`App/Views/Meadow.swift`, decision 0023).
- **Inspector** (`App/Views/Inspector.swift`): the right sidebar, ⌥⌘I or the glass toggle in the chat's top-right corner (View › Show Inspector), closed at launch. Both panes' toggles are Kuri's own (`PaneToggle`) and stay outside the panes they open: the sidebar's is a toolbar item of the chat's column (macOS's own toggle, which sits inside the open sidebar, is removed), so macOS keeps it at the column's leading edge and moves it with the sidebar; the inspector's is drawn over the chat, since as a toolbar item it would land over the inspector. *Steps* lists the conversation's tool calls under the message that led to them, commands first in mono with their exit status and duration (click for the output); *Tasks* is the plan, editable; *Context* splits the estimate into system, memory, messages and tool output, with the compaction mark at `compactAt`; *Git* shows each attached repository's branch, ahead/behind, changed files with line counts and last commit, read with the host's git (`RepositoryStatus` in `KuriAgent`, refreshed when folders change, a step finishes or Kuri comes to the front); *Sandbox* shows whether the container is running a command, awake (up, until its idle minutes pass) or asleep (no VM), and a terminal of the commands run for the latest message, the running one live from `.toolOutput` events; it opens only once the current turn has run a command. There's no persistent shell to show: every command is a fresh `/bin/sh -lc` in `/work`; what carries over is the files, and, until the container sleeps, anything written elsewhere in it. The sections are boxes in a column, each folding from its header, with Sandbox pinned at the bottom ([decision 0021](decisions/0021-inspector.md)). What the sections show is worked out when the items change, not as they render: `AppModel` keeps the steps (each call's arguments decoded once, as a `ToolSummary`) and the plan, and only a running command's row and the terminal read its live output. Git status stays in the model between openings, the first read after opening lands without animation so it doesn't fight the inspector's slide, and a repository lists its first 12 changes until Show all.
- **Menu bar icon and mini window** (`App/Mini/`): an `NSStatusItem`. Left click shows or hides the mini window, a small chat floating above other windows like picture in picture: a non-activating `NSPanel` (typing doesn't make Kuri the active app) whose content view is an `NSGlassEffectView`. Its title bar has close and maximize (which opens the chat in the main window) and, on the right, the chat's title opening a list of chats. Text is a size down (`chatScale`), panels are glass with no fill (`glassOnly`), Markdown has no LaTeX (`allowsMath`), and the composer is one line, two at most, with only send/stop; the folder and model pickers sit above it. The glass has no corner radius of its own, so the window's mask rounds it at the system's radius. Right-clicking the title bar offers Open Kuri. The mini window has its own `AppModel` on the same engine (`start(sharing:)`), so it can show a different chat ([decision 0020](decisions/0020-mini-window.md)). Right click opens a native menu: Open Kuri, Settings, Quit. The app keeps running with no windows open, and is in the Dock and ⌘-Tab only while the main window or Settings is open (`Dock` in `MiniWindow.swift`).
- **Settings**: *General* picks the theme (system, light, dark), sets Open at login (a macOS login item, through `SMAppService`) and Start in the background (only the menu bar icon at launch), toggles generated titles, sets when to compact (`compactAt`) and shows where the config lives; *Models* saves each provider's API key in the Keychain, registers models per provider (with discovery, asked again once a key is saved), edits their context windows and sets the default; *Tools* lists built-in tools and MCP servers with their state and policies; *Sandbox* sets it up and edits its image, CPUs, memory and idle timeout; *Memory* views and edits what Kuri remembers. Providers and MCP servers are still edited in their files.
- **Replies** are Markdown, parsed by Foundation and drawn block by block (`App/Views/Markdown.swift`); fenced code is coloured in Everforest Higure or Yoake by `App/Style/Highlighter.swift`, with a copy button ([decision 0017](decisions/0017-markdown-on-foundation.md)). LaTeX is typeset by MathJax in JavaScriptCore into SVG images placed in the text (`App/Style/MathRenderer.swift`, [decision 0019](decisions/0019-latex-with-mathjax.md)). The transcript is a lazy stack: only messages near the visible area are built, which keeps memory flat however long a conversation gets (built eagerly, each Markdown-heavy answer held about 5 MB). Parsed replies, highlighted code and typeset formulas are cached in bounded `NSCache`s.
- **Styling**: `App/Style/Style.swift` holds the palette (read from the environment), timings, faces, controls and pencil icons, so the look lives in one place. `Sketches/` is where directions are tried first (`Autumn.swift` for the window, `Inspector.swift` for the inspector).

## Distribution and security

- Distributed outside the Mac App Store: Developer ID signing, Hardened Runtime, notarization.
- **No App Sandbox.** Child processes inherit it, which breaks stdio MCP servers (`npx`, `uvx`) and real shell work. Safety comes from Kuri's own layers instead: the container VM (which only sees the attached folders) and the permission policy.
- Entitlements: `com.apple.security.virtualization` (`App/Kuri.entitlements`), for the sandbox's VMs.
- Secrets in the Keychain; logs through `os.Logger`.

## Testing

- `swift test` in `Packages/KuriKit` runs the unit and integration tests, including MCP servers written as Python fixtures (standard library only) and engine tests against a stubbed Open Responses endpoint.
- Live tests run real turns against a model and are skipped unless `KURI_LIVE_MODEL` names one (`KURI_LIVE_MODEL=ollama/qwen3.5:2b swift test --filter LiveTests`). Small models aren't deterministic, so they assert on what the plumbing guarantees and print transcripts.
- Real sandbox VMs need the virtualization entitlement on the running executable, which `swift test` can't have; they're exercised from a signed executable (see [CLAUDE.md](../CLAUDE.md)).
