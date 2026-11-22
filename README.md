# Kuri

A native macOS app for working with language models — local or hosted — that can chat, think, and act on your files from a sandbox.

Kuri is a single app that is both the engine and the interface: no server to deploy, no database service, no Docker. It runs offline with local models, talks to any hosted provider when you want it to, discovers MCP servers at runtime, and runs the model's commands inside a lightweight Linux VM. It needs an Apple silicon Mac with macOS 26 and Xcode 26.

> Status: early. Working: the Open Responses adapter, the agent loop, the built-in tools, MCP servers with runtime discovery, durable turns, compaction, the Linux sandbox with its `shell` tool, and a basic app whose UI will be redesigned once the engine is complete.

| Document | What's in it |
|---|---|
| [docs/design.md](docs/design.md) | How each part works, in detail |
| [docs/flows.html](docs/flows.html) | Every flow as a sequence diagram, and the event and protocol reference (open it in a browser) |
| [docs/config.md](docs/config.md) | Every configuration key |
| [docs/decisions/](docs/decisions/) | Why things are the way they are |
| [CLAUDE.md](CLAUDE.md) | Working agreements, build and test commands |

---

## Principles

- **Essential.** Few features, done well. Few dependencies, and only official ones (Apple, or the protocol's own SDK). No "personal" or small third-party libraries.
- **Local-first.** Works with no network. Hosted providers are opt-in.
- **Mac-only, Mac-native.** SwiftUI + AppKit, Apple frameworks, macOS conventions. No cross-platform abstractions.
- **Hackable.** Providers, models and MCP servers live in plain JSON5 files you can edit by hand. The database is a plain SQLite file with a small, readable schema.
- **Provider-agnostic.** Every major wire format is a first-class adapter. Switching model mid-conversation just works.
- **One mode.** There is no "chat mode" vs "code mode". Every conversation has the same tools; attaching a folder is what lets the model work on your files.

## Architecture

```
┌───────────────────────────────────── Kuri.app ─────────────────────────────────────┐
│                                                                                    │
│  App (SwiftUI)   main window · menu bar · settings                                 │
│        │  observes EngineEvents, calls Engine methods                              │
│        ▼                                                                           │
│  KuriAgent       Engine (actor) ── TurnRunner ── InteractionBroker                 │
│        │                                                                           │
│        ├────────────┬────────────┬────────────┬────────────┬────────────┐          │
│        ▼            ▼            ▼            ▼            ▼            ▼          │
│  KuriInference  KuriMCP      KuriSandbox  KuriTools    KuriStore    KuriConfig     │
│  adapters       MCP servers  Linux VMs,   registry,    SQLite       JSON5 files,   │
│  (HTTP + SSE)   → tools      shell tool   built-ins    file         Keychain       │
│        └────────────┴────── KuriCore (domain types) ───────┴────────────┘          │
│                                                                                    │
│  Each sandbox VM runs in its own system process (Virtualization.framework).        │
└────────────────────────────────────────────────────────────────────────────────────┘
```

**The engine is in-process.** The SwiftUI layer talks to `Engine` directly and subscribes to its event stream. A future network server (for an iOS client) is just another subscriber to the same stream; the local UI never goes through HTTP.

**Stateless towards providers.** Every request carries the history it needs, rebuilt from Kuri's database, as a list of items (messages, reasoning, tool calls and results, summaries) rather than chat messages. That keeps behaviour identical across providers, works offline, and makes switching model mid-conversation trivial.

**Configuration in files, data in SQLite.** Providers, models, tool policies and MCP servers live in JSON5 files in `~/.config/kuri`; conversations live in one small SQLite file; secrets in the Keychain.

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
| `KuriSandbox` | Linux containers on Apple's Containerization: setup, one VM per conversation, mounts; the `shell` tool | Core, Config, Tools |
| `KuriMarkdown` *(planned)* | Streaming Markdown → SwiftUI renderer on `swift-markdown` | — |

Dependencies point one way: down towards `KuriCore`. Nothing in the package imports SwiftUI.

```
Kuri/
├─ Kuri.xcodeproj         The app target (sources are a folder-synchronized group)
├─ App/                   SwiftUI app
├─ Packages/KuriKit/      Everything that isn't UI: the modules above, and their tests
├─ docs/                  Design, flows, configuration, decisions
├─ CLAUDE.md              Working agreements and commands
└─ Sketches/              UI experiments (not part of the build)
```

## Tools

Every tool implements `Tool`: a spec (name, description, JSON Schema), a default policy, whether it is read-only, and an async `run`. The `ToolRegistry` holds them all, built-in and discovered alike, each tagged with its source (`builtIn` or `mcp(server:)`), and decides which ones the model sees.

| Tool | What it does | Default |
|---|---|---|
| `clarify` | Ask the user one or more questions and wait for the answers | allow |
| `tasklist` | Write the current plan (the whole list each call) | allow |
| `memory` | Add, update or remove long-term memories, in one batched call | allow |
| `conversation_search` | Full-text search over past conversations, or this one | allow |
| `shell` | Run a command in the conversation's Linux container, from `/work` | allow (it's sandboxed) |
| MCP tools | Discovered at runtime, named `<server>__<tool>` | allow if the server marks them read-only, else ask |

Policies (`allow`, `ask`, `deny`) can be set per tool in `config.json` and per MCP server in `mcp.json`. There are no file tools and no artifacts: the shell lists, reads, searches and writes files, and a file the model creates is just a file. See [docs/design.md](docs/design.md#tools).

## Providers

| Wire format | Used for |
|---|---|
| `open-responses` | OpenAI, Ollama, LM Studio, vLLM, and anything else speaking the Open Responses spec |
| `anthropic-messages` | Anthropic's API *(planned)* |
| `gemini` | Google's native API *(planned)* |
| `chat-completions` | Legacy fallback for servers that only speak `/v1/chat/completions` *(planned)* |
| `apple-foundation-models` | Apple's on-device model, used for small jobs: titles, summaries, memory review *(planned)* |

Every adapter turns its wire format into the same item model and event stream; no official Swift SDK exists for these providers, so the adapters are hand-written over `URLSession`.

## Dependencies

| Dependency | Why | When |
|---|---|---|
| Apple frameworks (SwiftUI, AppKit, Foundation, Security, SQLite3, Virtualization) | Everything | Now |
| [modelcontextprotocol/swift-sdk](https://github.com/modelcontextprotocol/swift-sdk) | MCP client | Now |
| [apple/swift-log](https://github.com/apple/swift-log) | The SDK's logging API, which a custom transport has to implement | Now |
| [apple/containerization](https://github.com/apple/containerization) | Sandbox (pinned to an exact version: its API moves between minor versions) | Now |
| [swiftlang/swift-markdown](https://github.com/swiftlang/swift-markdown) | Markdown parsing | With `KuriMarkdown` |

The MCP SDK brings in, transitively, `apple/swift-system`, `apple/swift-log` and `mattt/eventsource` (SSE parsing for its HTTP transport); those are what end up linked into Kuri. SwiftPM also fetches `apple/swift-nio` and friends, used only by the SDK's own sample executables.

Containerization is the heavy one: it brings gRPC (`grpc/grpc-swift-2` and friends, to talk to the VM's init process), SwiftNIO, swift-crypto, swift-protobuf, `swift-server/async-http-client` and `facebook/zstd`. All come from Apple, the Swift server workgroup, gRPC or Meta; no personal libraries.

---

## Roadmap

Done, the core: foundations (domain model, config, storage, Open Responses adapter, agent loop), the built-in tools, MCP with runtime discovery, durable turns and compaction, the sandbox with folder attachment and the `shell` tool.

**Next: finish the engine.** The UI stays functional and minimal until then.

1. **Message queue** — type while a turn runs: the message joins the running turn at its next step, after the current tool round, or starts the next turn if it ends first. *(done)*
2. **Apple's on-device model** as a provider (`apple-foundation-models`), offline and free, a natural utility model.
3. **Generated titles**, switchable in Settings.
4. **Read-only tool calls in parallel.**

**Later, engine:** more providers (Anthropic Messages, Gemini, Chat Completions), fallback models, memory review, attachments in messages, sub-agents, `KuriServer` for the iOS client.

**Then: the UI redesign.** Streaming Markdown renderer, theming and the style layer, mini panel and global hotkey, conversation management, editing providers and MCP servers from Settings.
