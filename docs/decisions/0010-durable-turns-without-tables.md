# 0010. Durable turns without extra tables

Status: accepted

## Context
A turn can wait on the user (a clarify question, an approval) for a long time, and Kuri may quit meanwhile.

## Decision
While a tool waits for the user, the turn's status is `awaiting_input`. Nothing else is stored: the tool call is already an item, and a call without a result *is* the pending state. On launch, `resumePendingTurns()` re-runs those calls through the normal path, which asks again. Turns that were mid-stream at quit are marked failed ("Interrupted") rather than resumed, because a tool may have half-run; Continue starts a turn without a new message, and calls left without results get placeholder results.

## Consequences
- No table to keep consistent with the items.
- Policies are re-evaluated on resume (an approval may no longer be needed).
- The app must subscribe to events before resuming, or it misses the re-asked requests.
