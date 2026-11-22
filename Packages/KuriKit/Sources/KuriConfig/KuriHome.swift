import Foundation

/// The `~/.kuri` folder and everything in it.
///
/// Override the location with the `KURI_HOME` environment variable.
public struct KuriHome: Sendable {
    public let root: URL

    public init(root: URL) {
        self.root = root
    }

    public static func resolve(environment: [String: String] = ProcessInfo.processInfo.environment) -> KuriHome {
        if let custom = environment["KURI_HOME"], !custom.isEmpty {
            return KuriHome(root: URL(filePath: (custom as NSString).expandingTildeInPath, directoryHint: .isDirectory))
        }
        return KuriHome(root: FileManager.default.homeDirectoryForCurrentUser.appending(path: ".kuri", directoryHint: .isDirectory))
    }

    public var configFile: URL { root.appending(path: "config.json") }
    public var mcpFile: URL { root.appending(path: "mcp.json") }
    public var database: URL { root.appending(path: "kuri.sqlite") }
    public var blobs: URL { root.appending(path: "blobs", directoryHint: .isDirectory) }
    public var scratch: URL { root.appending(path: "scratch", directoryHint: .isDirectory) }

    public func scratchFolder(for conversationID: UUID) -> URL {
        scratch.appending(path: conversationID.uuidString.lowercased(), directoryHint: .isDirectory)
    }

    /// Creates the folder structure if it doesn't exist yet.
    public func prepare() throws {
        let fm = FileManager.default
        for dir in [root, blobs, scratch] {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
    }
}
