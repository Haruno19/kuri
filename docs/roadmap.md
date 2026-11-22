# Roadmap

Done, the core: foundations (domain model, config, storage, Open Responses adapter, agent loop), the built-in tools, MCP with runtime discovery, durable turns and compaction, the sandbox with folder attachment and the `shell` tool.

**Next: finish the engine.** The UI stays functional and minimal until then.

1. **Message queue** — type while a turn runs: the message joins the running turn at its next step, after the current tool round, or starts the next turn if it ends first. *(done)*
2. **Apple's on-device model** as a provider (`apple-foundation-models`), offline and free, a natural utility model. *(done)*
3. **Generated titles**, switchable in Settings. *(done)*
4. **Read-only tool calls in parallel.** *(done)*
5. **Anthropic Messages** as a provider (`anthropic-messages`), for Anthropic's API and the servers that copy it. *(done)*
6. **Fallback models**: when a request fails before the model produced anything, the turn goes on with the next model in its `fallbacks`. *(done)*

**Later, engine:** more providers (Gemini, Chat Completions), attachments in messages, sub-agents, `KuriServer` for the iOS client.

**Then: the UI redesign.** Streaming Markdown renderer, theming and the style layer, mini panel and global hotkey, conversation management, editing providers and MCP servers from Settings.

## iOS client

`KuriCore`, `KuriInference` and `KuriAgent` contain nothing Mac-specific. An iOS app can either connect to a Mac running Kuri (a planned `KuriServer` module: HTTP + WebSocket over `Network.framework`, Bonjour discovery, pairing) or run on its own with hosted providers or the on-device model.
