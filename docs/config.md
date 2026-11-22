# Configuration reference

Kuri's configuration is two files in its home folder, both **JSON5** (comments, unquoted keys and trailing commas are fine). Kuri writes commented templates on first launch and reloads either file as soon as it changes; an invalid file is reported and ignored, and the previous configuration stays in effect.

## Where

The home folder resolves in this order:

1. `KURI_HOME`
2. `$XDG_CONFIG_HOME/kuri`
3. `~/.config/kuri`

```
~/.config/kuri/
├─ config.json   providers, models, defaults, tool policies, sandbox
├─ mcp.json      MCP servers
├─ kuri.sqlite   conversations, turns, items, memories (not configuration)
├─ blobs/        attachments
├─ scratch/      per-conversation working folders
└─ sandbox/      kernel, images and snapshots for the sandbox
```

When the app changes `config.json` itself (registering models, picking the default model), it rewrites the file as tidy JSON5. Keys it doesn't know survive; comments don't.

## Secrets

Anywhere a secret is accepted (`apiKey`, `headers`, an MCP server's `env`), the value is a reference:

| Value | Meaning |
|---|---|
| `"keychain:<name>"` | The generic password Kuri stored in the Keychain under that name (service `Kuri`) |
| `"env:<VAR>"` | The environment variable `VAR` |
| anything else | The literal value. It works, but it then sits in a plain file. |

## config.json

```json5
{
  defaultModel: "ollama/qwen3.5:2b",
  utilityModel: "ollama/qwen3.5:2b",
  providers: {
    ollama: { format: "open-responses", baseURL: "http://localhost:11434/v1", discoverModels: true },
    openai: { format: "open-responses", baseURL: "https://api.openai.com/v1", apiKey: "keychain:openai",
              models: [{ id: "gpt-5", reasoningEffort: "medium", contextWindow: 400000 }] },
  },
  tools: { memory: "deny", "github__*": "ask" },
  sandbox: { image: "docker.io/library/python:3-slim", memoryMiB: 2048 },
}
```

### Top level

| Key | Type | Default | Meaning |
|---|---|---|---|
| `defaultModel` | `"<provider>/<model>"` | none | The model new conversations start with. Everything after the first slash is the model id. |
| `utilityModel` | `"<provider>/<model>"` | none | A small, fast model for background jobs. Today: compaction summaries. Without it, the conversation's own model writes them. |
| `providers` | object | `{}` | Providers by name; the name is the part before the slash in model references. |
| `tools` | object | `{}` | Tool policies, see below. |
| `sandbox` | object | defaults below | The Linux sandbox. |

### `providers.<name>`

| Key | Type | Default | Meaning |
|---|---|---|---|
| `format` | string | required | The wire format: `open-responses` or `apple-foundation-models`. Recognized but not implemented yet: `anthropic-messages`, `gemini`, `chat-completions`. |
| `baseURL` | URL | required for HTTP formats | E.g. `http://localhost:11434/v1`. Requests go to `<baseURL>/responses`, model discovery to `<baseURL>/models`. Not used by `apple-foundation-models`. |
| `apiKey` | secret | none | Sent as `Authorization: Bearer <key>`. |
| `headers` | object of secrets | none | Extra HTTP headers on every request. |
| `models` | array | `[]` | Registered models: bare ids (`"qwen3.5:2b"`) or objects (below). Settings › Models edits this list. |
| `discoverModels` | bool | `false` | Also offer every model the provider lists at `<baseURL>/models`, without registering them. Refreshed at launch and on every reload. |

### Apple's on-device model

```json5
apple: { format: "apple-foundation-models", models: ["default"] },
```

- The only model id is `default` (the system model). Discovery lists it when the model can run on this Mac; otherwise it says why (Apple Intelligence off, Mac not eligible, model still downloading).
- It gets no tools, and its instructions don't mention any. Its context window is 4,096 tokens unless `contextWindow` says otherwise, so automatic compaction works without configuration.
- A natural `utilityModel`: `"apple/default"`.

### Model objects

| Key | Type | Meaning |
|---|---|---|
| `id` | string | The provider's model id. Required. |
| `contextWindow` | int | Tokens. Enables automatic compaction at 75%, and the context meter's maximum. Set it to what the runtime actually uses, which for local runtimes may be less than the model supports. |
| `maxOutputTokens` | int | Sent as `max_output_tokens`. |
| `reasoningEffort` | string | Sent as `reasoning.effort` (e.g. `low`, `medium`, `high`), for models that support it. |
| `name` | string | A display name. Stored, not shown yet. |
| `fallbacks` | array of model references | Models to try when this one fails. Accepted, not used yet. |

### `tools`

Tool name (as the model sees it) or `*` glob → `"allow"`, `"ask"` or `"deny"`. MCP tools are named `<server>__<tool>`. An exact name beats a glob, a longer glob beats a shorter one, and these rules win over `mcp.json` ones on the same name.

| Policy | Effect |
|---|---|
| `allow` | Runs without asking. |
| `ask` | Shows an approval panel first. |
| `deny` | Hidden from the model entirely. |

Defaults when no rule matches: built-in tools and `shell` allow; MCP tools allow if the server marks them read-only, ask otherwise.

### `sandbox`

| Key | Type | Default | Meaning |
|---|---|---|---|
| `image` | OCI reference | `docker.io/library/python:3-slim` | The image conversation containers start from. There's no network, so what it ships with is what the model can use. |
| `cpus` | int | `4` | Virtual CPUs per container VM. |
| `memoryMiB` | int | `2048` | Memory per container VM. A VM keeps its peak use until it stops, so this caps its worst case. |
| `idleMinutes` | int | `10` | Minutes without a command before a conversation's container stops and its memory is released. |
| `kernel` | path | none | A Linux kernel (`vmlinux`) already on disk, used instead of downloading one. |
| `kernelURL` | URL | Kata Containers 4.3.1 arm64 tarball | Where setup downloads the kernel tarball from. |

Changing `image`, `cpus`, `memoryMiB` or the kernel stops running containers; a new image needs setup again.

## mcp.json

```json5
{
  mcpServers: {
    github: {
      url: "https://api.githubcopilot.com/mcp/",
      headers: { Authorization: "keychain:github-mcp" },
      tools: { "create_*": "ask", "*": "allow" },
    },
    notes: { command: "uvx", args: ["my-notes-mcp"], env: { NOTES_DIR: "env:HOME" }, enabled: false },
  },
}
```

### `mcpServers.<name>`

| Key | Type | Meaning |
|---|---|---|
| `command` | string | Launches a stdio server. Looked up in your login shell's `PATH`. |
| `args` | array of strings | Arguments for `command`. |
| `env` | object of secrets | Extra environment variables for `command`. |
| `url` | URL | A Streamable HTTP server, instead of `command`. |
| `headers` | object of secrets | HTTP headers on every request to `url`. OAuth isn't supported yet. |
| `enabled` | bool | `false` keeps the server declared but disconnected. Default `true`. |
| `tools` | object | Policies for this server's tools, by the server's own names (`*` globs allowed). |

The server name becomes the prefix of its tools' names (`<server>__<tool>`, characters outside `A–Z a–z 0–9 _ -` replaced by `_`, 64 characters at most).

## Environment variables

| Variable | Used by | Meaning |
|---|---|---|
| `KURI_HOME` | the app | Home folder override. |
| `XDG_CONFIG_HOME` | the app | Parent of the default home folder. |
| `KURI_LIVE_MODEL` | live tests | `<provider>/<model>` to run live tests against; unset skips them. |
| `KURI_LIVE_BASE_URL` | live tests | The provider's base URL. Default `http://localhost:11434/v1`. |
