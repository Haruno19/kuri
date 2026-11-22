import Foundation

/// Signals when anything in the `~/.kuri` folder changes.
///
/// Watches the folder rather than the files: editors save by writing a new
/// file and renaming it over the old one, which a per-file watch would miss.
/// Bursts of events are coalesced, so one save yields one signal.
public enum ConfigWatcher {
    public static func changes(in home: KuriHome, debounce: TimeInterval = 0.25) -> AsyncStream<Void> {
        AsyncStream { continuation in
            let fd = open(home.root.path(percentEncoded: false), O_EVTONLY)
            guard fd >= 0 else {
                continuation.finish()
                return
            }
            let queue = DispatchQueue(label: "kuri.config-watcher")
            let source = DispatchSource.makeFileSystemObjectSource(
                fileDescriptor: fd, eventMask: [.write, .rename, .delete], queue: queue)
            let pending = PendingFlag()
            source.setEventHandler {
                guard pending.set() else { return }
                queue.asyncAfter(deadline: .now() + debounce) {
                    pending.clear()
                    continuation.yield()
                }
            }
            source.setCancelHandler { close(fd) }
            source.resume()
            continuation.onTermination = { _ in source.cancel() }
        }
    }
}

/// Only touched from the watcher's serial queue.
private final class PendingFlag: @unchecked Sendable {
    private var isSet = false

    /// Returns `true` if the flag was clear.
    func set() -> Bool {
        defer { isSet = true }
        return !isSet
    }

    func clear() { isSet = false }
}
