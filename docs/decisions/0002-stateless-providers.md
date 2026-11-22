# 0002. Stateless towards providers; the database is the source of truth

Status: accepted

## Context
Some APIs (OpenAI's Responses API) can keep conversation state server-side. Local runtimes (Ollama, LM Studio) only implement the stateless form. Kuri works offline and lets the user switch models mid-conversation.

## Decision
Every request carries the whole history the model should see, rebuilt from Kuri's database: `store: false`, no `previous_response_id`, no provider-side threads.

## Consequences
- Identical behaviour across providers and offline; switching model mid-conversation needs nothing special.
- Requests are larger. Compaction (0011) keeps them within the context window.
- Provider-specific state the model needs back (encrypted reasoning) has to be stored with the item and replayed only to the provider that produced it.
