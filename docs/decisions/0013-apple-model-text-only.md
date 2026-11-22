# 0013. Apple's on-device model is text only

Status: accepted

## Context
Apple's on-device model (FoundationModels) is offline, free and private, which makes it ideal for chat and background jobs. It has a 4,096-token context window. FoundationModels supports tools, but runs them itself, inside the session, while Kuri's tools must go through the registry's policies, approvals and persistence (0009, 0010).

## Decision
The `apple-foundation-models` adapter offers the model no tools. Providers declare `supportsTools`; when it's false, requests carry no tool specs and the instructions mention no tools. Earlier tool calls and results (from turns with other models) are described to it in text. Its context window defaults to 4,096 tokens.

## Consequences
- Conversations can switch to the on-device model and back without breaking.
- It can't use the shell, MCP or built-in tools; it's for chat, titles and summaries.
- If a future FoundationModels version lets the caller handle tool calls, this can be revisited with a new record.
