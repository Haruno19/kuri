import Foundation
import KuriCore

/// What `kuri` was asked to do (decision 0028).
struct Invocation: Equatable {
    enum Command: Equatable {
        /// Interactive, or one turn with `-p`.
        case session
        case models
        case sandbox(SandboxAction)
        case help
        case version
    }

    enum SandboxAction: String {
        case status, setup
    }

    enum Resume: Equatable {
        /// `-c`: the latest conversation attached to this folder.
        case latestHere
        /// `-r` alone: choose from the recent ones.
        case pick
        /// `-r <id>`: by id prefix.
        case id(String)
    }

    var command: Command = .session
    /// The words after the options, joined: the first message.
    var prompt: String?
    var print = false
    var resume: Resume?
    var model: ModelRef?
    var attachCurrentFolder = true
    var readOnly = false
    var extraFolders: [String] = []
}

struct UsageError: Error {
    let message: String
}

extension Invocation {
    static func parse(_ arguments: [String]) throws -> Invocation {
        var invocation = Invocation()
        var args = arguments[...]

        // Subcommands only as the first word, so `kuri explain models` is a prompt.
        switch args.first {
        case "models":
            args.removeFirst()
            guard args.isEmpty else { throw UsageError(message: "`kuri models` takes no arguments") }
            invocation.command = .models
            return invocation
        case "sandbox":
            args.removeFirst()
            let word = args.popFirst() ?? SandboxAction.status.rawValue
            guard let action = SandboxAction(rawValue: word), args.isEmpty else {
                throw UsageError(message: "use `kuri sandbox status` or `kuri sandbox setup`")
            }
            invocation.command = .sandbox(action)
            return invocation
        default:
            break
        }

        var words: [String] = []
        var onlyWords = false
        func setResume(_ resume: Resume) throws {
            guard invocation.resume == nil else { throw UsageError(message: "-c and -r can't be used together") }
            invocation.resume = resume
        }
        func value(for option: String) throws -> String {
            guard let value = args.popFirst() else { throw UsageError(message: "\(option) needs a value") }
            return value
        }

        while let arg = args.popFirst() {
            if onlyWords || !arg.hasPrefix("-") || arg == "-" {
                words.append(arg)
                continue
            }
            switch arg {
            case "--":
                onlyWords = true
            case "-p", "--print":
                invocation.print = true
            case "-c", "--continue":
                try setResume(.latestHere)
            case "-r", "--resume":
                // An id prefix is hex (and dashes); anything else is the prompt.
                if let next = args.first, next.wholeMatch(of: /[0-9a-fA-F-]{4,36}/) != nil {
                    args.removeFirst()
                    try setResume(.id(next.lowercased()))
                } else {
                    try setResume(.pick)
                }
            case "-m", "--model":
                let text = try value(for: arg)
                guard let model = ModelRef(text) else {
                    throw UsageError(message: "a model is provider/model, as in config.json (got “\(text)”)")
                }
                invocation.model = model
            case "--no-folder":
                invocation.attachCurrentFolder = false
            case "--read-only":
                invocation.readOnly = true
            case "--add":
                invocation.extraFolders.append(try value(for: arg))
            case "-h", "--help":
                return Invocation(command: .help)
            case "--version":
                return Invocation(command: .version)
            default:
                throw UsageError(message: "unknown option \(arg)")
            }
        }

        invocation.prompt = words.isEmpty ? nil : words.joined(separator: " ")
        let foldersChosen = !invocation.attachCurrentFolder || invocation.readOnly || !invocation.extraFolders.isEmpty
        if invocation.resume != nil, foldersChosen {
            throw UsageError(message: "--no-folder, --read-only and --add only apply to a new conversation")
        }
        if invocation.readOnly, !invocation.attachCurrentFolder, invocation.extraFolders.isEmpty {
            throw UsageError(message: "--read-only with --no-folder leaves nothing to attach")
        }
        if invocation.print, invocation.resume == .pick {
            throw UsageError(message: "-p can't ask which conversation: give -r an id")
        }
        return invocation
    }

    static let help = """
        Kuri in the terminal.

        Usage:
          kuri [options] [prompt]       a session in this folder; the prompt is its first message
          kuri -p [options] <prompt>    one turn: print the answer and exit
          kuri models                   list the models you can use
          kuri sandbox [status|setup]   show or set up the sandbox

        Options:
          -p, --print            one turn, the answer on stdout; piped stdin is added to the prompt
          -c, --continue         continue the latest conversation attached to this folder
          -r, --resume [id]      choose a recent conversation, or open one by id prefix
          -m, --model <ref>      provider/model, as in config.json
              --no-folder        don't attach this folder
              --read-only        attach folders read-only
              --add <path>       attach another folder (repeatable)
          -h, --help             show this help
              --version          show the version

        In a session, /help lists its commands. Ctrl-C stops a turn, Ctrl-D quits.
        Kuri and kuri share ~/.config/kuri, and one runs at a time.
        """
}
