# Working on Kuri

Kuri is a native macOS app for working with language models, local or hosted: an in-process engine (the `KuriKit` Swift package) and a SwiftUI app around it. Read these before changing anything substantial:

- [README.md](README.md): what Kuri is, its principles, architecture, tools, providers and dependencies.
- [docs/design.md](docs/design.md): how each part works, in detail.
- [docs/flows.html](docs/flows.html): every flow as a sequence diagram with the code behind each step, plus the engine-event and protocol reference.
- [docs/decisions/](docs/decisions/): why things are the way they are. Don't reverse a decision without a new record that supersedes it.
- [docs/config.md](docs/config.md): every configuration key.
- [docs/ui.md](docs/ui.md): the UI and UX brief (principles, style, layout, UI roadmap).

## Current priorities

The engine is done; the work now is the UI redesign, following [docs/ui.md](docs/ui.md). Try directions as standalone sketches in `Sketches/` first, agree on one with the author, then apply it to `App/`. Motion and feedback get the most care and will be tuned back and forth: keep timings as named constants.

## Principles that shape every change

- **Essential.** Few features, done well. Prefer removing a concept to adding one (the shell replaced file tools; there are no artifacts).
- **Dependencies.** Apple frameworks first. Otherwise only official SDKs and libraries from the organization behind a technology (Apple, the Swift server workgroup, the MCP project, gRPC…), never personal or small third-party ones. Pin anything whose API moves (Containerization is pinned exactly). Every dependency is listed with its reason in the README.
- **The engine knows nothing about SwiftUI.** The app calls `Engine` methods and observes `Engine.events()`. A future network server will be just another subscriber.
- **Stateless towards providers.** The database is the source of truth; every request is rebuilt from it.
- **Derive, don't store.** No table for state that can be read from items (pending questions, the task list) or kept in memory (MCP discovery).
- **Configuration lives in `~/.config/kuri/*.json` (JSON5); data in SQLite; secrets in the Keychain.** Never copy config into the database.
- **Tools go through `ToolRegistry`** and its allow / ask / deny policies, whatever their source.

## Working agreements

- Commit directly on `main`, one commit per coherent step. Commit messages say what changed and why. Push only when asked.
- Never name the author's employer or its projects in code, comments, docs or commit messages.
- When a flow changes, update its diagram in `docs/flows.html` (flows are data at the bottom of the page) and the event reference if events change. Every step names the line that does it (`'path:line: code'`); when code moves, run `python3 docs/sync-flow-refs.py`. `FlowReferenceTests` fails until every reference holds its code.
- When a config key is added or changes meaning, update `docs/config.md` and the template in `ConfigLoader`.
- When making a decision that future work should respect, add a record in `docs/decisions/`.
- Database migrations are append-only: never edit a shipped one in `Migrations.swift`, add the next.
- Keep the README an overview: its module table, tool and provider lists and dependencies in step with the code. Detailed explanations go in `docs/design.md`.

## Build and test

```bash
# Package: unit and integration tests (MCP fixtures need /usr/bin/python3)
cd Packages/KuriKit && swift test

# Live tests: real turns against a model (skipped unless KURI_LIVE_MODEL is set)
cd Packages/KuriKit && KURI_LIVE_MODEL=ollama/qwen3.5:2b swift test --filter LiveTests
# The same over the Anthropic format (Ollama speaks it too); KURI_LIVE_API_KEY for a hosted API
cd Packages/KuriKit && KURI_LIVE_MODEL=ollama/qwen3.5:2b KURI_LIVE_FORMAT=anthropic-messages swift test --filter LiveTests

# App (builds and embeds the `kuri` CLI too)
xcodebuild -project Kuri.xcodeproj -scheme Kuri -configuration Debug build
```

- Tests use Swift Testing. Fixture servers are Python scripts using only the standard library.
- Starting a sandbox VM needs the `com.apple.security.virtualization` entitlement on the running executable, which `swift test` can't have. To exercise real VMs, build a small executable that depends on `KuriKit` by path, sign it (`codesign -f -s - --entitlements <plist> <binary>`), and drive `Sandbox` or `Engine` from it. Use a separate `KURI_HOME` (symlinking its `sandbox/` to the installed one) so real conversations aren't touched.
- To try `kuri`, run the build in DerivedData (`…/Build/Products/Debug/kuri`, built by either scheme) with its own `KURI_HOME`, like a VM test, and with the app closed: one engine at a time. Interactive behaviour (prompts, Ctrl-C) needs a terminal, so drive it through a pseudo-terminal (Python's `pty`). To debug it, Run the `KuriCLI` scheme: it waits for `kuri` to be started from a terminal and attaches.
- Live tests use small local models, which aren't deterministic: assert on what the plumbing guarantees, print transcripts for the rest.

## Code conventions

- Swift 6 with strict concurrency. Shared mutable state lives in actors (`Engine`, `Store`, `ToolRegistry`, `MCPManager`, `Sandbox`); cross-actor callbacks carry a generation number when stale ones must be ignored.
- The app and CLI targets use main-actor default isolation; the package doesn't.
- Doc comments explain *why*, not what the next line does.
- Errors meant for people are `KuriError` cases with readable descriptions.

## Where things live

- `~/.config/kuri/`: `config.json`, `mcp.json`, `kuri.sqlite`, `kuri.lock` (one engine at a time), `scratch/<conversation>/`, `sandbox/` (kernel, images, snapshots).
- `Packages/KuriKit/Sources/`: `KuriCore` (types) → `KuriConfig`, `KuriStore`, `KuriInference`, `KuriTools` → `KuriMCP`, `KuriSandbox` → `KuriAgent` (the engine).
- `App/`: the SwiftUI shell (folder-synchronized in the Xcode project: new files are picked up automatically).
- `CLI/`: the `kuri` command-line client, a tool target embedded in the app at `Contents/Helpers` (decision 0028), folder-synchronized the same way.
