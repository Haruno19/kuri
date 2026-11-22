# 0003. Conversations are items, not messages

Status: accepted

## Context
A chat-messages model (`role` + `content`) fits plain chat but not tool calls, reasoning, or summaries, and every provider shapes those differently.

## Decision
A conversation is an ordered list of items: `message`, `reasoning`, `toolCall`, `toolResult`, `compaction`, close to the Open Responses item model. Every adapter maps its wire format to and from items. Items are stored append-only, one row each, with their JSON payload and searchable text.

## Consequences
- One model for every provider, and for the UI's transcript.
- Adapters do the shape-shifting (for instance, a compaction becomes a user message for providers that have no such concept).
- Storage stays simple and append-only; derived state (pending questions, the task list) can be read back from items.
