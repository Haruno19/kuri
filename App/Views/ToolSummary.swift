import Foundation
import KuriCore
import KuriTools

/// How a tool call reads, worked out once per call (its arguments are JSON
/// to decode): the transcript, the inspector and the working status say it
/// the same way. Built-ins get their own wording; MCP tools read
/// "server › tool".
struct ToolSummary: Equatable {
    let glyph: Glyph
    /// The whole command, for `shell`.
    let command: String?
    /// The plan a `tasklist` call carries.
    let tasks: [TaskListTool.Entry]
    private let kind: Kind

    private enum Kind: Equatable {
        case shell, memory, clarify
        case tasklist(byUser: Bool)
        case search(query: String?)
        case other(String)
    }

    init(_ call: ToolCall) {
        var command: String?
        var tasks: [TaskListTool.Entry] = []
        switch call.name {
        case "shell":
            glyph = .terminal
            kind = .shell
            command = Self.arguments(call)["command"]?.stringValue ?? ""
        case "tasklist":
            glyph = .checklist
            kind = .tasklist(byUser: TaskListTool.isUserEdit(call))
            tasks = TaskListTool.entries(fromArguments: call.arguments) ?? []
        case "memory":
            glyph = .bookmark
            kind = .memory
        case "conversation_search":
            glyph = .search
            kind = .search(query: Self.arguments(call)["query"]?.stringValue)
        case "clarify":
            glyph = .question
            kind = .clarify
        default:
            glyph = .puzzle
            let parts = call.name.components(separatedBy: "__")
            kind = .other(parts.count > 1 ? "\(parts[0]) › \(parts.dropFirst().joined(separator: "__"))" : call.name)
        }
        self.command = command
        self.tasks = tasks
    }

    var isShell: Bool { kind == .shell }

    /// A multi-line command shows its first line.
    var commandLine: String {
        guard let command else { return "" }
        return command.split(whereSeparator: \.isNewline).first.map(String.init) ?? command
    }

    /// What the call did, or is doing while it has no result.
    func title(finished: Bool) -> String {
        switch kind {
        case .shell: commandLine
        case .tasklist(let byUser):
            "\(byUser ? "You edited" : "Updated") the plan · \(tasks.filter { $0.status == .completed }.count)/\(tasks.count) done"
        case .memory: finished ? "Updated memory" : "Updating memory"
        case .search(let query): "Searched past conversations" + (query.map { " for “\($0)”" } ?? "")
        case .clarify: finished ? "Asked you" : "Waiting for your answer"
        case .other(let name): name
        }
    }

    /// The working indicator's words while the call runs.
    var status: String {
        switch kind {
        case .shell: "Running a command"
        case .tasklist: "Updating the plan"
        case .memory: "Updating memory"
        case .search: "Searching past conversations"
        case .clarify: "Waiting for your answer"
        case .other(let name): "Using \(name)"
        }
    }

    private static func arguments(_ call: ToolCall) -> [String: JSONValue] {
        (try? JSONDecoder().decode([String: JSONValue].self, from: Data(call.arguments.utf8))) ?? [:]
    }
}
