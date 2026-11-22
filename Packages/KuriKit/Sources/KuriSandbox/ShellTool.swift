import Foundation
import KuriCore
import KuriTools

/// Runs commands in the conversation's Linux container. The only way the
/// model touches files: listing, reading, searching and editing all go
/// through it, on the folders mounted at `/work`.
public struct ShellTool: Tool {
    public static let name = "shell"
    static let defaultTimeout = 120
    static let maxTimeout = 900
    /// Characters returned to the model: the start and, mostly, the end.
    static let headCharacters = 8_000
    static let tailCharacters = 20_000

    let sandbox: Sandbox
    let scratch: @Sendable (UUID) -> URL

    public init(sandbox: Sandbox, scratch: @escaping @Sendable (UUID) -> URL) {
        self.sandbox = sandbox
        self.scratch = scratch
    }

    public let spec = ToolSpec(
        name: ShellTool.name,
        description: """
            Run a shell command in this conversation's Linux sandbox and get its output and exit code. \
            The working directory is /work, where the conversation's folders are (see your instructions). \
            Files written under /work persist; everything else is disposable, since the container may be \
            restarted. There is no network access. Commands run with /bin/sh -lc; call bash explicitly for \
            bash features. Use it to list, read, search and edit files, and to run programs. Keep commands \
            non-interactive, and pass timeout_seconds for long ones.
            """,
        parameters: [
            "type": "object",
            "properties": [
                "command": ["type": "string", "description": "The command line to run."],
                "timeout_seconds": [
                    "type": "integer", "minimum": 1, "maximum": 900,
                    "description": "Stop the command after this many seconds. Default 120.",
                ],
            ],
            "required": ["command"],
        ])

    private struct Arguments: Decodable {
        let command: String
        let timeout_seconds: Int?
    }

    public func run(arguments: Data, context: ToolContext) async throws -> ToolOutput {
        let args = try decode(Arguments.self, from: arguments)
        guard !args.command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .error("`command` is empty.")
        }
        let timeout = min(max(args.timeout_seconds ?? Self.defaultTimeout, 1), Self.maxTimeout)
        let mounts = SandboxMounts.plan(folders: context.folders, scratch: scratch(context.conversationID))
        let result = try await sandbox.run(args.command, conversationID: context.conversationID, mounts: mounts,
                                           timeout: .seconds(timeout))
        return Self.output(for: result, timeout: timeout)
    }

    static func output(for result: CommandResult, timeout: Int) -> ToolOutput {
        let status = if result.timedOut {
            "Timed out after \(timeout) s; the command was stopped."
        } else {
            "Exit code \(result.exitCode.map(String.init) ?? "unknown")."
        }
        let text = result.output.isEmpty ? "(no output)" : trimmed(result.output)
        return ToolOutput("\(status)\n\(text)", isError: result.timedOut)
    }

    /// Long output keeps its start and end; errors tend to be at the end.
    static func trimmed(_ output: String) -> String {
        guard output.count > headCharacters + tailCharacters else { return output }
        let head = output.prefix(headCharacters)
        let tail = output.suffix(tailCharacters)
        return "\(head)\n[… \(output.count - headCharacters - tailCharacters) characters …]\n\(tail)"
    }
}
