# Roadmap

Done, the core: foundations (domain model, config, storage, Open Responses adapter, agent loop), the built-in tools, MCP with runtime discovery, durable turns and compaction, the sandbox with folder attachment and the `shell` tool.

Then the engine: everything below is done.

1. **Message queue** — type while a turn runs: the message joins the running turn at its next step, after the current tool round, or starts the next turn if it ends first. *(done)*
2. **Apple's on-device model** as a provider (`apple-foundation-models`), offline and free, a natural utility model. *(done)*
3. **Generated titles**, switchable in Settings. *(done)*
4. **Read-only tool calls in parallel.** *(done)*
5. **Anthropic Messages** as a provider (`anthropic-messages`), for Anthropic's API and the servers that copy it. *(done)*
6. **Fallback models**: when a request fails before the model produced anything, the turn goes on with the next model in its `fallbacks`. *(done)*

**Later, engine:** more providers (Gemini, Chat Completions), sub-agents, `KuriServer` for the iOS client.

**Now: the UI redesign**, briefed in [ui.md](ui.md) and tried in `Sketches/Autumn.swift`:

1. Full Markdown, including LaTeX; code blocks in the Everforest colours (Higure dark, Yoake light). *(done)*
2. Layout and styling of the main window, with conversation management (rename, archive, delete; maybe projects or grouping by root folder). Running chats get a single-orb status indicator in the sidebar; the sidebar snaps shut when dragged past a threshold.
3. Menu bar icon and mini window: a small glass chat floating above other windows, with its own chat and a native right-click menu. *(done)*
4. Settings window, including editing providers and MCP servers. *(theme, context windows, compaction and sandbox options done)*
5. A global hotkey for the mini window.
6. A right-hand sidebar, the conversation's inspector: its steps (shell commands first), the task list (editable), the context, git status for repository folders, and a sandbox preview while the model uses it. *(done)*
7. Playing with the main window for a polished, slightly retro feel: a background pattern, the logo's size, pixel animations around the composer.

## iOS client

`KuriCore`, `KuriInference` and `KuriAgent` contain nothing Mac-specific. An iOS app can either connect to a Mac running Kuri (a planned `KuriServer` module: HTTP + WebSocket over `Network.framework`, Bonjour discovery, pairing) or run on its own with hosted providers or the on-device model.
