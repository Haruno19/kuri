# 0016. Retry replaces the answer

**Decided.** Retry answers the last user message again by deleting every item after it (the previous answer, its reasoning and tool calls, any summary made meanwhile) and starting a new turn from that message. Only the latest answer can be retried, and not while a turn runs. The old turn's row stays, with its usage.

This amends [decision 0003](0003-items-not-messages.md): items are append-only except for this one operation.

**Why.** Keeping every attempt (answer versions you page through) means items that are hidden from the model but kept for the user, a notion of the active branch in every request, and UI to switch between them. That is a feature of its own; retrying is a small, frequent action, and what people want from it is a better answer in place. Deleting keeps one linear history that the model and the transcript share.

**Cost.** A retried answer is gone; there is no undo. Search follows (the full-text index has a delete trigger). Side effects of the old answer outside the conversation (files changed in attached folders, memories saved) aren't undone: retry rewinds the conversation, not the disk.
