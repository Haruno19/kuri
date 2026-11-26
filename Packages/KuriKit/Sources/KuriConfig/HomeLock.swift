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
/// The file only names the holder and its process id, for the error the
/// next one sees: with the id, a client can offer to quit the other.
public final class HomeLock: Sendable {
    private let descriptor: Mutex<Int32>

    private init(descriptor: Int32) {
        self.descriptor = Mutex(descriptor)
    }

    /// Takes the lock, or throws `KuriError.homeInUse` naming the process
    /// that holds it.
    public static func acquire(_ home: KuriHome, holder: String = defaultHolder,
                               pid: Int32 = ProcessInfo.processInfo.processIdentifier) throws -> HomeLock {
        let path = home.lockFile.path
        let fd = open(path, O_RDWR | O_CREAT | O_CLOEXEC, 0o644)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            let code = errno
            close(fd)
            guard code == EWOULDBLOCK else { throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO) }
            let lines = ((try? String(contentsOfFile: path, encoding: .utf8)) ?? "")
                .split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
            throw KuriError.homeInUse(home: (home.root.path as NSString).abbreviatingWithTildeInPath,
                                      holder: lines.first.flatMap { $0.isEmpty ? nil : $0 },
                                      pid: lines.count > 1 ? Int32(lines[1]) : nil)
        }
        ftruncate(fd, 0)
        let label = Array("\(holder)\n\(pid)\n".utf8)
        _ = label.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
        return HomeLock(descriptor: fd)
    }

    /// "Kuri (process 812)" or "kuri (process 4242)".
    public static var defaultHolder: String {
        let process = ProcessInfo.processInfo
        return "\(process.processName) (process \(process.processIdentifier))"
    }

    /// The program a process runs, so a client offering to quit the other
    /// can make sure the id it read from the lock is still that client's.
    public static func executable(of pid: Int32) -> URL? {
        var path = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        guard proc_pidpath(pid, &path, UInt32(path.count)) > 0 else { return nil }
        return URL(filePath: String(cString: path))
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
