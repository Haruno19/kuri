import Foundation
import KuriStore

/// Where a conversation's folders appear inside its container.
///
/// One folder (or the scratch folder, when none is attached) is `/work`;
/// several are `/work/<name>`. The shell's working directory is `/work`, so
/// the model sees one path namespace whatever is attached.
public struct SandboxMount: Sendable, Hashable {
    public var hostPath: String
    public var guestPath: String
    public var readOnly: Bool
    /// True for the conversation's scratch folder.
    public var isScratch: Bool
}

public enum SandboxMounts {
    public static let workdir = "/work"

    public static func plan(folders: [ConversationFolder], scratch: URL) -> [SandboxMount] {
        if folders.isEmpty {
            return [SandboxMount(hostPath: scratch.path(percentEncoded: false), guestPath: workdir,
                                 readOnly: false, isScratch: true)]
        }
        if folders.count == 1 {
            return [SandboxMount(hostPath: folders[0].path, guestPath: workdir,
                                 readOnly: folders[0].readOnly, isScratch: false)]
        }
        var used: Set<String> = []
        return folders.map { folder in
            let base = safeName(URL(filePath: folder.path).lastPathComponent)
            var name = base
            var suffix = 2
            while used.contains(name) {
                name = "\(base)-\(suffix)"
                suffix += 1
            }
            used.insert(name)
            return SandboxMount(hostPath: folder.path, guestPath: "\(workdir)/\(name)",
                                readOnly: folder.readOnly, isScratch: false)
        }
    }

    /// A folder name usable as a path component in the guest.
    static func safeName(_ name: String) -> String {
        let cleaned = String(name.map { $0 == "/" || $0 == "\0" ? "_" : $0 })
            .trimmingCharacters(in: .whitespaces)
        return cleaned.isEmpty || cleaned == "." || cleaned == ".." ? "folder" : cleaned
    }
}
