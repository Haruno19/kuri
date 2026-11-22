# 0004. No App Sandbox; safety comes from the VM and tool policies

Status: accepted

## Context
The App Sandbox is inherited by child processes. Stdio MCP servers (`npx`, `uvx`, …) and real shell work need a normal environment, and the user attaches arbitrary folders.

## Decision
Kuri isn't sandboxed. It's distributed outside the Mac App Store (Developer ID, Hardened Runtime, notarization). Safety comes from Kuri's own layers: the model's shell runs in a Linux VM that only sees the attached folders (0012), and every tool call goes through allow / ask / deny policies (0009).

## Consequences
- MCP servers and the sandbox work as users expect.
- No Mac App Store distribution.
- Kuri is responsible for its own boundaries: the VM, the policies, and never running model-chosen commands on the host.
