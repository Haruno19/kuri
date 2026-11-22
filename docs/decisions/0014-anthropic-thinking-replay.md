# 0014. Anthropic thinking is replayed only within the current exchange

Status: accepted

## Context
Claude's thinking blocks come back with a signature, and sending them back unchanged lets the model pick up its reasoning. The signature also records the history that produced the block: the system prompt, the set of tools and every earlier message. When that history has changed, the API refuses the request (on accounts where the check is enforced) or drops the block. Removing a leading run of thinking blocks is always allowed.

Kuri rebuilds every request (0002), and parts of it change between requests by design: the instructions carry the date, the memories and the attached folders; the tools follow MCP servers; and compaction keeps the latest exchange verbatim after a summary (0011), so the blocks in it were produced from a history that no longer exists.

## Decision
- The adapter replays thinking only within the current exchange (from the latest user message that doesn't join a tool round), and only blocks its own provider produced. Earlier blocks are left out, which is a leading run.
- `TurnRunner.history` clears the opaque state of reasoning stored before the latest compaction, for every provider: it belongs to the history the summary replaced.
- Every request sets `thinking.block_binding.prefix_mismatch_behavior: "drop_block"` (with its beta header), so a change in the middle of an exchange (a memory saved, an MCP server reconnecting) drops what no longer matches instead of failing the turn.

## Consequences
- A day boundary, a memory edit or a compaction never breaks a conversation.
- The model doesn't see its thinking from earlier exchanges, only their text and tool calls. That costs some continuity and saves input tokens; older Claude models discarded it anyway.
- Starting a new exchange rewrites the prompt cache from the previous exchange's first thinking block on.
- Keeping the instructions fixed for a conversation, with changes appended as system messages, would allow replaying everything. If Kuri moves to that, this can be revisited with a new record.
