# 0012. The sandbox: Containerization, one VM per conversation, no network

Status: accepted

## Context
The model needs a real shell on the user's files without touching the host. Docker would be a heavy external dependency; Apple's Containerization runs each Linux container in its own lightweight VM.

## Decision
`KuriSandbox` uses Containerization, pinned to an exact version. One kind of container, one per conversation, started on the first `shell` call, stopped when idle, recreated when folders change. Folders are mounted at `/work` (a scratch folder when none is attached), read-only when asked; there is no network device. The kernel comes from the Kata Containers release tarball (only the kernel is kept); Apple's `vminit` image and the sandbox image are pulled once and the image unpacked into a snapshot that containers clone. Virtualization.framework runs each VM in its own system process, so there's no extra XPC service.

## Consequences
- Fast (about half a second to a first command) and offline after a one-time setup of about 0.8 GB.
- A VM keeps its peak memory until it stops (capped by `memoryMiB`); idle stop releases it.
- Real VMs can't be started from `swift test` (entitlement), so they're exercised from a signed executable.
- macOS-native commands aren't available to the model by design.
