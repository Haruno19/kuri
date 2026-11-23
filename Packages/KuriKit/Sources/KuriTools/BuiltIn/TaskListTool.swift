import Foundation
import KuriCore

/// Keeps a visible plan for multi-step work.
///
/// The model sends the whole list on every call. There's no table: the
/// current list is the arguments of the latest call, which `current(in:)`
/// reads back from the conversation's items.
public struct TaskListTool: Tool {
    public init() {}

    public struct Entry: Codable, Sendable, Hashable {
        public enum Status: String, Codable, Sendable {
            case pending
            case inProgress = "in_progress"
            case completed
        }

        public var content: String
        public var status: Status

        public init(content: String, status: Status) {
            self.content = content
            self.status = status
        }
    }

    public let spec = ToolSpec(
        name: "tasklist",
        description: """
            Write the task list for the current work, replacing the previous one. Use it for work with \
            three or more steps. Send the whole list every time, keep exactly one task in_progress while \
            working, and mark tasks completed as soon as they're done.
            """,
        parameters: [
            "type": "object",
            "properties": [
                "tasks": [
                    "type": "array",
                    "items": [
                        "type": "object",
                        "properties": [
                            "content": ["type": "string", "description": "Short imperative phrase."],
                            "status": ["type": "string", "enum": ["pending", "in_progress", "completed"]],
                        ],
                        "required": ["content", "status"],
                    ],
                ],
            ],
            "required": ["tasks"],
        ])

    private struct Arguments: Codable {
        let tasks: [Entry]
    }

    public var isReadOnly: Bool { true }

    public func run(arguments: Data, context: ToolContext) async throws -> ToolOutput {
        let tasks = try decode(Arguments.self, from: arguments).tasks
        let inProgress = tasks.filter { $0.status == .inProgress }.count
        if inProgress > 1 {
            return .error("Only one task can be in_progress at a time; \(inProgress) are.")
        }
        let done = tasks.filter { $0.status == .completed }.count
        return ToolOutput("Task list updated: \(done)/\(tasks.count) done.")
    }

    /// The user's own changes to the list (from the inspector) are stored
    /// as a call and its result, like the model's: the current list stays
    /// the arguments of the latest call, and the model reads the change in
    /// its history. Their ids start with this.
    public static let userCallPrefix = "kuri_user_tasklist_"

    /// A call and result carrying the user's version of the list.
    public static func userEdit(_ entries: [Entry]) -> (ToolCall, ToolResult) {
        let id = userCallPrefix + UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        let arguments = (try? JSONEncoder().encode(Arguments(tasks: entries))).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
        let done = entries.filter { $0.status == .completed }.count
        let output = "The user edited the task list (\(done)/\(entries.count) done). It replaces yours: follow it from here."
        return (ToolCall(id: id, name: "tasklist", arguments: arguments), ToolResult(callID: id, output: output, isError: false))
    }

    public static func isUserEdit(_ call: ToolCall) -> Bool {
        call.id.hasPrefix(userCallPrefix)
    }

    /// The list carried by one call's arguments, if they're valid.
    public static func entries(fromArguments arguments: String) -> [Entry]? {
        try? JSONDecoder().decode(Arguments.self, from: Data(arguments.utf8)).tasks
    }

    /// The latest successful task list in a conversation.
    public static func current(in items: [Item]) -> [Entry] {
        var failed: Set<String> = []
        for item in items.reversed() {
            switch item.payload {
            case .toolResult(let result) where result.isError:
                failed.insert(result.callID)
            case .toolCall(let call) where call.name == "tasklist" && !failed.contains(call.id):
                if let entries = entries(fromArguments: call.arguments) { return entries }
            default:
                continue
            }
        }
        return []
    }
}
