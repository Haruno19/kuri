# 0008. MCP through the official SDK, with our own stdio transport

Status: accepted

## Context
MCP is JSON-RPC and small enough to implement by hand, but there's an official Swift SDK. Its stdio transport takes file descriptors and polls them every 10 ms while idle, which wastes energy in an app that stays open in the background.

## Decision
Kuri uses the official MCP Swift SDK for the protocol and its HTTP transport. Stdio servers go through `ProcessTransport`, our own implementation of the SDK's `Transport` protocol: it launches the server and is driven by readability callbacks. The login shell's `PATH` is used so commands resolve as in Terminal.

## Consequences
- Protocol changes come with SDK updates; Kuri owns only process handling.
- An idle server costs nothing; stderr becomes a log; an exiting server is noticed and its tools removed.
- The SDK brings `mattt/eventsource` transitively, the one non-organizational library in the tree.
