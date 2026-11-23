import Foundation

/// Where a folder stands in git: branch, how far it is from its upstream,
/// what changed, the last commit. Read-only, for the inspector: Kuri isn't a
/// git client, and the model has `git` in the sandbox for anything else.
public struct RepositoryStatus: Sendable, Hashable {
    public struct Change: Sendable, Hashable {
        public enum Kind: Character, Sendable {
            case modified = "M", added = "A", deleted = "D", renamed = "R", untracked = "?", conflicted = "U"
        }

        public var path: String
        public var kind: Kind
        /// Lines, against `HEAD`; `nil` for binary or untracked files.
        public var added: Int?
        public var removed: Int?
    }

    public struct Commit: Sendable, Hashable {
        public var hash: String
        public var subject: String
        public var date: Date
    }

    /// `nil` on a detached HEAD.
    public var branch: String?
    public var ahead = 0
    public var behind = 0
    public var changes: [Change] = []
    public var lastCommit: Commit?

    /// Whether a real git is installed (Homebrew's or the developer tools').
    public static var isGitAvailable: Bool { Git.executable != nil }

    /// The folder's status, or `nil` when it isn't in a repository or git
    /// isn't installed. Uses the host's git, without taking the index lock,
    /// so it never gets in the way of a command running in the sandbox.
    public static func read(at folder: String) async -> RepositoryStatus? {
        guard let git = Git.executable else { return nil }
        let run = { (arguments: [String]) in await Git.run(git, ["-C", folder, "--no-optional-locks"] + arguments) }
        guard let status = await run(["status", "--porcelain=v2", "--branch", "-z"]) else { return nil }
        var result = parse(status: status)
        if let numstat = await run(["diff", "HEAD", "--numstat", "-z", "-M"]) {
            result.apply(numstat: numstat)
        }
        if let log = await run(["log", "-1", "--format=%h%x00%s%x00%ct"]) {
            let parts = log.trimmingCharacters(in: .newlines).components(separatedBy: "\0")
            if parts.count == 3, let seconds = TimeInterval(parts[2]) {
                result.lastCommit = Commit(hash: parts[0], subject: parts[1], date: Date(timeIntervalSince1970: seconds))
            }
        }
        return result
    }

    /// `git status --porcelain=v2 --branch -z`.
    static func parse(status: String) -> RepositoryStatus {
        var result = RepositoryStatus()
        var fields = status.components(separatedBy: "\0")[...]
        while let field = fields.popFirst() {
            if field.hasPrefix("# branch.head ") {
                let name = String(field.dropFirst("# branch.head ".count))
                result.branch = name == "(detached)" ? nil : name
            } else if field.hasPrefix("# branch.ab ") {
                let counts = field.dropFirst("# branch.ab ".count).split(separator: " ")
                if counts.count == 2 {
                    result.ahead = Int(counts[0].dropFirst()) ?? 0
                    result.behind = Int(counts[1].dropFirst()) ?? 0
                }
            } else if field.hasPrefix("1 ") || field.hasPrefix("2 ") {
                // "1 XY sub mH mI mW hH hI path"; "2" adds a score, and the
                // original path follows as the next field.
                let parts = field.split(separator: " ", maxSplits: field.hasPrefix("1 ") ? 8 : 9, omittingEmptySubsequences: false)
                guard let xy = parts.dropFirst().first, let path = parts.last else { continue }
                if field.hasPrefix("2 ") { _ = fields.popFirst() }
                result.changes.append(Change(path: String(path), kind: kind(xy), added: nil, removed: nil))
            } else if field.hasPrefix("u ") {
                if let path = field.split(separator: " ", maxSplits: 10, omittingEmptySubsequences: false).last {
                    result.changes.append(Change(path: String(path), kind: .conflicted, added: nil, removed: nil))
                }
            } else if field.hasPrefix("? ") {
                result.changes.append(Change(path: String(field.dropFirst(2)), kind: .untracked, added: nil, removed: nil))
            }
        }
        return result
    }

    private static func kind(_ xy: Substring) -> Change.Kind {
        let codes = Set(xy)
        if codes.contains("R") || codes.contains("C") { return .renamed }
        if codes.contains("A") { return .added }
        if codes.contains("D") { return .deleted }
        return .modified
    }

    /// `git diff HEAD --numstat -z -M`: "added\tremoved\tpath", or for a
    /// rename "added\tremoved\t" then the old and new paths as fields.
    mutating func apply(numstat: String) {
        var fields = numstat.components(separatedBy: "\0")[...]
        while let field = fields.popFirst(), !field.isEmpty {
            let parts = field.split(separator: "\t", maxSplits: 2, omittingEmptySubsequences: false)
            guard parts.count == 3 else { continue }
            var path = String(parts[2])
            if path.isEmpty {
                _ = fields.popFirst()
                path = fields.popFirst() ?? ""
            }
            guard let index = changes.firstIndex(where: { $0.path == path }) else { continue }
            changes[index].added = Int(parts[0])
            changes[index].removed = Int(parts[1])
        }
    }
}

enum Git {
    /// A real git, never `/usr/bin/git` without developer tools: that one is
    /// a stub that asks to install them.
    static let executable: String? = {
        let fileManager = FileManager.default
        for path in ["/opt/homebrew/bin/git", "/usr/local/bin/git"] where fileManager.isExecutableFile(atPath: path) {
            return path
        }
        for developer in ["/Library/Developer/CommandLineTools", "/Applications/Xcode.app/Contents/Developer"] {
            let path = developer + "/usr/bin/git"
            if fileManager.isExecutableFile(atPath: path) { return path }
        }
        return nil
    }()

    /// Standard output, or `nil` if git failed. On a dispatch queue: it
    /// blocks while git runs, which mustn't hold a Swift concurrency thread.
    static func run(_ executable: String, _ arguments: [String]) async -> String? {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                let process = Process()
                process.executableURL = URL(filePath: executable)
                process.arguments = arguments
                process.environment = ["GIT_TERMINAL_PROMPT": "0", "LC_ALL": "C", "PATH": "/usr/bin:/bin:/usr/sbin:/sbin"]
                let output = Pipe()
                process.standardOutput = output
                process.standardError = FileHandle.nullDevice
                process.standardInput = FileHandle.nullDevice
                do {
                    try process.run()
                } catch {
                    continuation.resume(returning: nil)
                    return
                }
                // Read to the end before waiting: a full pipe would block git.
                let data = output.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                continuation.resume(returning: process.terminationStatus == 0 ? String(decoding: data, as: UTF8.self) : nil)
            }
        }
    }
}
