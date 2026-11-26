import Foundation
import KuriAgent
import KuriCore
import KuriSandbox
import KuriStore

/// `kuri models` and `kuri sandbox`.
enum Commands {
    /// Every model `-m` and `/model` accept: the declared ones and, for
    /// providers that discover theirs, what they serve now (the engine's own
    /// discovery runs in the background and may not have finished).
    static func models(_ engine: Engine) async -> Int32 {
        let out = Stream.out
        let config = await engine.config
        var models = await engine.models
        for (name, provider) in config.providers.sorted(by: { $0.key < $1.key }) where provider.discoverModels == true {
            for id in (try? await engine.availableModels(provider: name)) ?? [] {
                let model = ModelRef(provider: name, model: id)
                if !models.contains(model) { models.append(model) }
            }
        }
        guard !models.isEmpty else {
            Stream.err.line("kuri: no models yet: add one in Kuri's Settings › Models")
            return 1
        }
        for model in models {
            out.line(model == config.defaultModel ? "\(model)  " + out.style("default", .dim) : model.description)
        }
        return 0
    }

    static func sandbox(_ action: Invocation.SandboxAction, _ engine: Engine) async -> Int32 {
        let out = Stream.out
        let settings = SandboxSettings(await engine.config.sandbox)
        switch action {
        case .status:
            switch await engine.sandbox.status {
            case .ready:
                out.line("Ready")
                out.line(out.style("\(settings.image) · \(settings.cpus) CPUs · \(settings.memoryMiB) MiB · stops after \(settings.idleMinutes) idle minutes", .dim))
            case .notInstalled:
                out.line("Not set up: kuri sandbox setup downloads a Linux kernel and the image (\(settings.image)).")
            case .installing(let step, _):
                out.line("Setting up: \(step)")
            case .failed(let message):
                out.line("Failed: \(message)")
                return 1
            }
            return 0
        case .setup:
            if await engine.sandbox.status == .ready {
                out.line("The sandbox is already set up.")
                return 0
            }
            let events = engine.events()
            let progress = Task {
                var lastStep = ""
                for await event in events {
                    guard case .sandboxChanged(.installing(let step, let fraction)) = event else { continue }
                    let percent = fraction.map { String(format: " %3.0f%%", $0 * 100) } ?? ""
                    if out.isTerminal {
                        out.write("\r\u{1B}[K\(step)" + out.style(percent, .dim))
                    } else if step != lastStep {
                        out.line(step)
                    }
                    lastStep = step
                }
            }
            defer { progress.cancel() }
            do {
                try await engine.setUpSandbox()
                out.endLine()
                out.line("Ready")
                return 0
            } catch {
                out.endLine()
                Stream.err.line("kuri: \(error.localizedDescription)")
                return 1
            }
        }
    }
}

/// Finding the conversation `-c` and `-r` mean.
enum Conversations {
    /// How many `-r` offers.
    static let recent = 10

    static func latest(attachedTo path: String, in engine: Engine) async throws -> Conversation? {
        let all = try await engine.store.conversations().sorted { $0.updatedAt > $1.updatedAt }
        for conversation in all where try await engine.folders(of: conversation.id).contains(where: { Folders.same($0.path, path) }) {
            return conversation
        }
        return nil
    }

    static func find(_ prefix: String, in engine: Engine) async throws -> Conversation {
        let matches = try await engine.store.conversations(includeArchived: true)
            .filter { $0.id.uuidString.lowercased().hasPrefix(prefix) }
        switch matches.count {
        case 0: throw UsageError(message: "no conversation's id starts with \(prefix)")
        case 1: return matches[0]
        default: throw UsageError(message: "\(matches.count) conversations' ids start with \(prefix): give more of it")
        }
    }

    /// Lists the recent conversations and reads a number; `nil` if none is chosen.
    static func pick(in engine: Engine) async throws -> Conversation? {
        let out = Stream.out
        let all = try await engine.store.conversations().sorted { $0.updatedAt > $1.updatedAt }
        guard !all.isEmpty else { throw UsageError(message: "there are no conversations yet") }
        let shown = Array(all.prefix(recent))
        let ages = RelativeDateTimeFormatter()
        for (index, conversation) in shown.enumerated() {
            let folders = try await engine.folders(of: conversation.id).map { Folders.display($0.path) }
            let details = [ages.localizedString(for: conversation.updatedAt, relativeTo: .now)] + folders
            out.line(out.style(String(format: "%2d", index + 1), .dim) + "  "
                     + (conversation.title.isEmpty ? "Untitled" : conversation.title)
                     + out.style("  " + details.joined(separator: " · "), .dim))
        }
        out.write("Which one? " + out.style("(number, or Return to cancel)", .dim) + " ")
        guard let line = readLine(), let number = Int(line.trimmingCharacters(in: .whitespaces)),
              shown.indices.contains(number - 1)
        else { return nil }
        return shown[number - 1]
    }
}

/// The folders a new conversation gets, and how paths are compared and shown.
enum Folders {
    static var current: String {
        FileManager.default.currentDirectoryPath
    }

    /// The current folder unless `--no-folder`, then `--add`'s. Not a whole
    /// home folder or disk on its own, though: that's more than a session
    /// opened by habit should get, and `--add` says it on purpose.
    static func forNewConversation(_ invocation: Invocation) throws -> ([ConversationFolder], note: String?) {
        var folders: [ConversationFolder] = []
        var note: String?
        if invocation.attachCurrentFolder {
            let home = FileManager.default.homeDirectoryForCurrentUser.path
            if same(current, home) || same(current, "/") {
                note = "\(display(current)) isn't attached: it's your whole \(same(current, "/") ? "disk" : "home folder"). --add attaches it anyway."
            } else {
                folders.append(ConversationFolder(path: current, readOnly: invocation.readOnly))
            }
        }
        for path in invocation.extraFolders {
            let resolved = try resolve(path)
            if !folders.contains(where: { same($0.path, resolved) }) {
                folders.append(ConversationFolder(path: resolved, readOnly: invocation.readOnly))
            }
        }
        return (folders, note)
    }

    /// An absolute path to an existing folder, from what was typed.
    static func resolve(_ path: String) throws -> String {
        let expanded = (path as NSString).expandingTildeInPath
        let url = URL(filePath: expanded, relativeTo: URL(filePath: current, directoryHint: .isDirectory)).standardizedFileURL
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw UsageError(message: "no folder at \(path)")
        }
        return url.path
    }

    static func same(_ a: String, _ b: String) -> Bool {
        func canonical(_ path: String) -> String {
            URL(filePath: path).resolvingSymlinksInPath().standardizedFileURL.path
        }
        return canonical(a) == canonical(b)
    }

    static func display(_ path: String) -> String {
        (path as NSString).abbreviatingWithTildeInPath
    }

    static func describe(_ folder: ConversationFolder) -> String {
        display(folder.path) + (folder.readOnly ? " (read-only)" : "")
    }
}
