import KuriCore
import KuriTools
import SwiftUI

/// One tool call in the transcript, with its result folded inside.
struct ToolCallView: View {
    let call: ToolCall
    let result: ToolResult?
    /// The turn is still running, so a missing result means "in progress".
    let isLive: Bool

    @State private var expanded = false

    var body: some View {
        let presentation = ToolPresentation(call: call, result: result)
        VStack(alignment: .leading, spacing: 6) {
            Button {
                withAnimation(.snappy) { expanded.toggle() }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: presentation.symbol)
                        .frame(width: 16)
                        .foregroundStyle(result?.isError == true ? .red : .secondary)
                    Text(presentation.title)
                        .lineLimit(1)
                    if result == nil && isLive {
                        ProgressView().controlSize(.mini)
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right")
                        .font(.caption2.weight(.semibold))
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                        .foregroundStyle(.tertiary)
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .font(.callout)
            .foregroundStyle(.secondary)

            if expanded {
                presentation.detail
                    .padding(.leading, 24)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }
}

/// How each tool reads in the transcript. Built-ins get their own wording;
/// MCP tools show as "server › tool".
private struct ToolPresentation {
    let symbol: String
    let title: String
    let detail: AnyView

    init(call: ToolCall, result: ToolResult?) {
        let output = result?.output
        switch call.name {
        case "clarify":
            symbol = "questionmark.bubble"
            title = result == nil ? "Waiting for your answer" : "Asked you"
            detail = AnyView(OutputText(text: output ?? ""))

        case "tasklist":
            let entries = TaskListTool.entries(fromArguments: call.arguments) ?? []
            let done = entries.filter { $0.status == .completed }.count
            symbol = "checklist"
            title = "Updated the plan · \(done)/\(entries.count) done"
            detail = AnyView(TaskListRows(entries: entries))

        case "memory":
            symbol = "brain"
            title = result == nil ? "Updating memory" : "Updated memory"
            detail = AnyView(OutputText(text: output ?? ""))

        case "shell":
            let command = (try? JSONDecoder().decode([String: JSONValue].self, from: Data(call.arguments.utf8)))?["command"]?.stringValue ?? ""
            let firstLine = command.split(whereSeparator: \.isNewline).first.map(String.init) ?? command
            symbol = "terminal"
            title = firstLine.count > 70 ? String(firstLine.prefix(67)) + "…" : firstLine
            detail = AnyView(VStack(alignment: .leading, spacing: 6) {
                if firstLine != command { OutputText(text: command) }
                OutputText(text: output ?? "")
            })

        case "conversation_search":
            let query = (try? JSONDecoder().decode([String: JSONValue].self, from: Data(call.arguments.utf8)))?["query"]?.stringValue
            symbol = "magnifyingglass"
            title = "Searched past conversations" + (query.map { " for “\($0)”" } ?? "")
            detail = AnyView(OutputText(text: output ?? ""))

        default:
            let parts = call.name.components(separatedBy: "__")
            symbol = parts.count > 1 ? "puzzlepiece.extension" : "wrench.and.screwdriver"
            title = parts.count > 1 ? "\(parts[0]) › \(parts.dropFirst().joined(separator: "__"))" : call.name
            detail = AnyView(VStack(alignment: .leading, spacing: 8) {
                OutputText(text: call.arguments)
                if let output { OutputText(text: output) }
            })
        }
    }
}

private struct OutputText: View {
    let text: String

    var body: some View {
        if !text.isEmpty {
            Text(text)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// The rows of a task list, shared by the transcript and the plan panel.
struct TaskListRows: View {
    let entries: [TaskListTool.Entry]

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            ForEach(Array(entries.enumerated()), id: \.offset) { _, entry in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: Self.symbol(for: entry.status))
                        .foregroundStyle(entry.status == .completed ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                    Text(entry.content)
                        .strikethrough(entry.status == .completed, color: .secondary)
                        .foregroundStyle(entry.status == .completed ? .secondary : .primary)
                        .fontWeight(entry.status == .inProgress ? .medium : .regular)
                }
            }
        }
        .font(.callout)
    }

    static func symbol(for status: TaskListTool.Entry.Status) -> String {
        switch status {
        case .pending: "circle"
        case .inProgress: "circle.dotted.circle"
        case .completed: "checkmark.circle.fill"
        }
    }
}
