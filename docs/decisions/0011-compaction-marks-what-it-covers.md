# 0011. A compaction names the last item it covers

Status: accepted

## Context
Long conversations outgrow context windows. A summary should replace the old part while the latest exchange stays word for word, and storage should stay append-only.

## Decision
A compaction is an item appended at the end, naming the last item it summarizes (`throughItemID`). Requests carry the summary, then every item after that one. The cut keeps the latest exchange (or its tail, never splitting a tool call from its result). Compaction runs automatically at 75% of the model's `contextWindow` (estimated at four characters per token), or on demand; the utility model writes it if set.

## Consequences
- The transcript keeps everything; only the model's view shrinks. `conversation_search` with `this_chat` recovers details the summary dropped.
- Without a `contextWindow` in config, compaction is manual only.
- The estimate is rough; a local runtime with a smaller real context may truncate before Kuri compacts.
