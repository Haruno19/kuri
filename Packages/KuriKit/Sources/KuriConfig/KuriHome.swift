import Foundation

/// The folder holding Kuri's configuration and data, `~/.config/kuri` by default.
///
/// Resolution order: `KURI_HOME`, then `$XDG_CONFIG_HOME/kuri`, then `~/.config/kuri`.
public struct KuriHome: Sendable {
    public let root: URL

    public init(root: URL) {
        self.root = root
    }

    public static func resolve(environment: [String: String] = ProcessInfo.processInfo.environment) -> KuriHome {
        if let custom = environment["KURI_HOME"], !custom.isEmpty {
            return KuriHome(root: URL(filePath: (custom as NSString).expandingTildeInPath, directoryHint: .isDirectory))
        }
        let configRoot: URL = if let xdg = environment["XDG_CONFIG_HOME"], !xdg.isEmpty {
            URL(filePath: (xdg as NSString).expandingTildeInPath, directoryHint: .isDirectory)
        } else {
            FileManager.default.homeDirectoryForCurrentUser.appending(path: ".config", directoryHint: .isDirectory)
        }
        return KuriHome(root: configRoot.appending(path: "kuri", directoryHint: .isDirectory))
    }

    public var configFile: URL { root.appending(path: "config.json") }
    public var mcpFile: URL { root.appending(path: "mcp.json") }
    public var database: URL { root.appending(path: "kuri.sqlite") }
    public var scratch: URL { root.appending(path: "scratch", directoryHint: .isDirectory) }
    /// Held by the running engine (`HomeLock`).
    public var lockFile: URL { root.appending(path: "kuri.lock") }

    public func scratchFolder(for conversationID: UUID) -> URL {
        scratch.appending(path: conversationID.uuidString.lowercased(), directoryHint: .isDirectory)
    }

    /// Creates the folder structure if it doesn't exist yet.
    public func prepare() throws {
        let fm = FileManager.default
        for dir in [root, scratch] {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
    }
}
