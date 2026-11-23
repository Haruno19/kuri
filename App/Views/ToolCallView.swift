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
    @Environment(AppModel.self) private var model
    @Environment(\.palette) private var palette
    @Environment(\.chatScale) private var scale

    var body: some View {
        let summary = model.summary(of: call)
        VStack(alignment: .leading, spacing: 6) {
            Button {
                withAnimation(.snappy) { expanded.toggle() }
            } label: {
                HStack(spacing: 8) {
                    PencilIcon(glyph: summary.glyph, size: 14 * scale,
                               color: result?.isError == true ? palette.accent : palette.faint, weight: 1.3)
                        .frame(width: 16 * scale)
                    Text(summary.title(finished: result != nil))
                        .lineLimit(1)
                    if result == nil && isLive {
                        Orb(size: 6)
                    }
                    PencilIcon(glyph: .chevron, size: 11, color: palette.faint)
                        .rotationEffect(.degrees(expanded ? 0 : -90))
                    Spacer(minLength: 0)
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .font(Typeface.sans(13 * scale))
            .foregroundStyle(palette.secondary)

            if expanded {
                ToolDetail(call: call, summary: summary, output: result?.output ?? "")
                    .padding(.leading, 24)
                    .transition(.opacity.combined(with: .offset(y: -4)))
            }
        }
    }
}

/// What a call opens to: the command and its output, the plan, or the
/// result (with the arguments, for MCP tools).
private struct ToolDetail: View {
    let call: ToolCall
    let summary: ToolSummary
    let output: String

    var body: some View {
        switch summary.kind {
        case .shell:
            VStack(alignment: .leading, spacing: 6) {
                if let command = summary.command, command != summary.commandLine { OutputText(text: command) }
                OutputText(text: output)
            }
        case .tasklist:
            TaskListRows(entries: summary.tasks)
        case .other:
            VStack(alignment: .leading, spacing: 8) {
                OutputText(text: call.arguments)
                OutputText(text: output)
            }
        default:
            OutputText(text: output)
        }
    }
}

private struct OutputText: View {
    let text: String

    var body: some View {
        if !text.isEmpty {
            Text(text)
                .font(Typeface.mono(11.5))
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// The rows of a task list, read-only: in the transcript and the plan
/// panel above the composer. The inspector's are editable, in the same
/// pencil style.
struct TaskListRows: View {
    let entries: [TaskListTool.Entry]
    @Environment(\.palette) private var palette

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            ForEach(Array(entries.enumerated()), id: \.offset) { _, entry in
                HStack(alignment: .top, spacing: 8) {
                    TaskCheck(status: entry.status)
                        .padding(.top, 1.5)
                    Text(entry.content)
                        .strikethrough(entry.status == .completed, color: palette.faint)
                        .foregroundStyle(entry.status == .completed ? palette.faint : palette.ink)
                        .fontWeight(entry.status == .inProgress ? .medium : .regular)
                }
            }
        }
        .font(Typeface.sans(13))
    }
}

/// Empty, in progress (a dot in the accent), or done (filled and ticked).
struct TaskCheck: View {
    let status: TaskListTool.Entry.Status
    @Environment(\.palette) private var palette

    var body: some View {
        ZStack {
            switch status {
            case .pending:
                Circle().strokeBorder(palette.faint.opacity(0.9), lineWidth: 1.2)
            case .inProgress:
                Circle().strokeBorder(palette.accent, lineWidth: 1.3)
                Circle().fill(palette.accentFill).padding(3.5)
            case .completed:
                Circle().fill(palette.accentFill)
                PencilIcon(glyph: .check, size: 10, color: .white, weight: 1.7)
            }
        }
        .frame(width: 14, height: 14)
        .contentShape(Circle())
    }
}
