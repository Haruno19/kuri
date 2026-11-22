# 0009. One policy model for every tool

Status: accepted

## Context
Built-in tools, MCP tools and the shell differ in risk, and users need control without per-feature settings.

## Decision
Every tool has a policy: `allow` runs it, `ask` shows an approval first, `deny` hides it from the model entirely. Defaults: built-ins and the sandboxed shell allow; MCP tools allow if the server marks them read-only, ask otherwise. Overrides come from `config.json` (`tools`, any tool, by the name the model sees) and `mcp.json` (per server, by the server's names). An exact name beats a glob, a longer glob beats a shorter one, and `config.json` wins on the same name.

## Consequences
- One mental model, one place (`ToolRegistry`) where it's enforced.
- Policies are configuration, so they're edited in files until the UI offers it.
