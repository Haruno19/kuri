import Foundation
import KuriCore
import Synchronization

/// Keeps one engine per home folder (decision 0028). The app and `kuri`
/// each run an engine of their own on the same files, and two at once
/// would mark each other's running turns as interrupted and race over
/// queues, approvals and VMs that live in memory.
///
/// An exclusive `flock` on `kuri.lock`: the kernel drops it when the
/// process exits, however it exits, so a crash never leaves a stale lock.
/// The file only names the holder, for the error the next one sees.
public final class HomeLock: Sendable {
    private let descriptor: Mutex<Int32>

    private init(descriptor: Int32) {
        self.descriptor = Mutex(descriptor)
    }

    /// Takes the lock, or throws `KuriError.homeInUse` naming the process
    /// that holds it.
    public static func acquire(_ home: KuriHome, holder: String = defaultHolder) throws -> HomeLock {
        let path = home.lockFile.path
        let fd = open(path, O_RDWR | O_CREAT | O_CLOEXEC, 0o644)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            let code = errno
            close(fd)
            guard code == EWOULDBLOCK else { throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO) }
            let current = (try? String(contentsOfFile: path, encoding: .utf8))?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            throw KuriError.homeInUse(home: (home.root.path as NSString).abbreviatingWithTildeInPath,
                                      holder: current?.isEmpty == false ? current : nil)
        }
        ftruncate(fd, 0)
        let label = Array("\(holder)\n".utf8)
        _ = label.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
        return HomeLock(descriptor: fd)
    }

    /// "Kuri (process 812)" or "kuri (process 4242)".
    public static var defaultHolder: String {
        let process = ProcessInfo.processInfo
        return "\(process.processName) (process \(process.processIdentifier))"
    }

    /// Lets the next engine open this home. Closing the descriptor is what
    /// drops the lock; the file stays, since removing it would race with a
    /// process about to lock it.
    public func release() {
        descriptor.withLock { fd in
            guard fd >= 0 else { return }
            close(fd)
            fd = -1
        }
    }

    deinit {
        release()
    }
}
