import Foundation
import Synchronization

/// The `PATH` the user has in Terminal.
///
/// An app launched from Finder or the Dock inherits a minimal `PATH`
/// (`/usr/bin:/bin:/usr/sbin:/sbin`), so `npx`, `uvx` or anything from
/// Homebrew isn't found. Asking the user's login shell once fixes that for
/// every stdio server.
enum LoginShell {
    private static let cached = Mutex<String??>(nil)

    static func path() async -> String? {
        if let value = cached.withLock({ $0 }) { return value }
        let value = await query()
        cached.withLock { $0 = .some(value) }
        return value
    }

    private static func query() async -> String? {
        await Task.detached(priority: .userInitiated) { blockingQuery() }.value
    }

    private static func blockingQuery() -> String? {
        let shell = ProcessInfo.processInfo.environment["SHELL"].flatMap { $0.isEmpty ? nil : $0 } ?? "/bin/zsh"
        let marker = "__KURI_PATH__"
        let process = Process()
        process.executableURL = URL(filePath: shell)
        // Interactive and login, so both .zprofile and .zshrc run: version
        // managers (pyenv, nvm, mise…) usually hook into the latter.
        process.arguments = ["-ilc", "printf '\(marker)%s\(marker)' \"$PATH\""]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice

        let exited = DispatchGroup()
        exited.enter()
        process.terminationHandler = { _ in exited.leave() }
        do {
            try process.run()
        } catch {
            return nil
        }
        // A broken shell config shouldn't stall every server.
        guard exited.wait(timeout: .now() + 5) == .success else {
            process.terminate()
            return nil
        }
        let text = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        let parts = text.components(separatedBy: marker)
        return parts.count >= 3 && !parts[1].isEmpty ? parts[1] : nil
    }
}
