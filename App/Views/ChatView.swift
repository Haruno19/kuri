import KuriAgent
import KuriCore
import KuriTools
import SwiftUI

/// Transcript and composer for the selected conversation.
///
/// Messages render with Foundation's inline Markdown for now; block-level
/// Markdown (code blocks, lists, tables) is what KuriMarkdown will add.
struct ChatView: View {
    @Environment(AppModel.self) private var model
    @State private var draft = ""

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    ForEach(TranscriptRow.rows(from: model.items)) { row in
                        TranscriptRowView(row: row, isLive: model.isSelectedRunning)
                    }
                    if !model.streamingReasoning.isEmpty {
                        Text(model.streamingReasoning)
                            .font(.callout).foregroundStyle(.secondary)
                    }
                    if !model.streamingText.isEmpty {
                        Text(model.streamingText)
                            .textSelection(.enabled)
                    }
                }
                .padding(20)
                .frame(maxWidth: 760)
                .frame(maxWidth: .infinity)
            }
            .defaultScrollAnchor(.bottom)

            ForEach(model.inputRequests.filter { $0.conversationID == model.selection }) { request in
                InputRequestView(request: request)
            }

            TaskListPanel(entries: model.taskList)

            composer
        }
        .navigationTitle(model.selectedConversation?.title.nilIfEmpty ?? "Kuri")
        .toolbar { modelPicker }
    }

    private var composer: some View {
        HStack(alignment: .bottom, spacing: 10) {
            TextField("Message Kuri…", text: $draft, axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(1...8)
                .onSubmit(send)
            if model.isSelectedRunning {
                Button("Stop", systemImage: "stop.fill") { Task { await model.cancel() } }
            } else {
                Button("Send", systemImage: "arrow.up") { send() }
                    .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .keyboardShortcut(.return, modifiers: .command)
            }
        }
        .labelStyle(.iconOnly)
        .padding(12)
        .background(.background.secondary, in: .rect(cornerRadius: 12))
        .padding([.horizontal, .bottom], 16)
    }

    @ToolbarContentBuilder
    private var modelPicker: some ToolbarContent {
        ToolbarItem {
            Menu {
                ForEach(model.models, id: \.self) { ref in
                    Button(ref.description) { Task { await model.setModel(ref) } }
                }
            } label: {
                Text(model.selectedConversation?.model?.description ?? "Model")
            }
            .disabled(model.selectedConversation == nil)
        }
    }

    private func send() {
        let text = draft
        draft = ""
        Task { await model.send(text) }
    }
}

/// What the transcript shows: items, except that a tool result is folded
/// into the call it answers.
enum TranscriptRow: Identifiable {
    case item(Item)
    case tool(id: UUID, call: ToolCall, result: ToolResult?)

    var id: UUID {
        switch self {
        case .item(let item): item.id
        case .tool(let id, _, _): id
        }
    }

    static func rows(from items: [Item]) -> [TranscriptRow] {
        var results: [String: ToolResult] = [:]
        for item in items {
            if case .toolResult(let result) = item.payload { results[result.callID] = result }
        }
        return items.compactMap { item in
            switch item.payload {
            case .toolCall(let call): .tool(id: item.id, call: call, result: results[call.id])
            case .toolResult: nil
            default: .item(item)
            }
        }
    }
}

private struct TranscriptRowView: View {
    let row: TranscriptRow
    let isLive: Bool

    var body: some View {
        switch row {
        case .tool(_, let call, let result):
            ToolCallView(call: call, result: result, isLive: isLive)
        case .item(let item):
            ItemView(payload: item.payload)
        }
    }
}

private struct ItemView: View {
    let payload: Item.Payload

    var body: some View {
        switch payload {
        case .message(let message) where message.role == .user:
            Text(message.text)
                .textSelection(.enabled)
                .padding(.horizontal, 12).padding(.vertical, 8)
                .background(.tint.opacity(0.15), in: .rect(cornerRadius: 12))
                .frame(maxWidth: .infinity, alignment: .trailing)

        case .message(let message):
            Text(Self.inlineMarkdown(message.text))
                .textSelection(.enabled)

        case .reasoning(let reasoning) where !reasoning.text.isEmpty:
            DisclosureGroup("Thinking") {
                Text(reasoning.text).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
            }
            .font(.callout).foregroundStyle(.secondary)

        case .compaction:
            Divider().overlay(Text("Earlier messages summarized").font(.caption).foregroundStyle(.secondary))

        default:
            EmptyView()
        }
    }

    static func inlineMarkdown(_ text: String) -> AttributedString {
        (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(text)
    }
}

/// The current plan, pinned above the composer while it has open tasks.
private struct TaskListPanel: View {
    let entries: [TaskListTool.Entry]
    @State private var expanded = true

    var body: some View {
        if !entries.isEmpty, entries.contains(where: { $0.status != .completed }) {
            let done = entries.filter { $0.status == .completed }.count
            VStack(alignment: .leading, spacing: 8) {
                Button {
                    withAnimation(.snappy) { expanded.toggle() }
                } label: {
                    HStack {
                        Label("Plan · \(done)/\(entries.count)", systemImage: "checklist")
                            .font(.callout.weight(.medium))
                        Spacer()
                        Image(systemName: "chevron.down")
                            .rotationEffect(.degrees(expanded ? 0 : -90))
                            .foregroundStyle(.tertiary)
                    }
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                if expanded {
                    TaskListRows(entries: entries)
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.background.secondary, in: .rect(cornerRadius: 12))
            .padding(.horizontal, 16).padding(.bottom, 8)
        }
    }
}

private struct InputRequestView: View {
    @Environment(AppModel.self) private var model
    let request: InputRequest
    @State private var answers: [String: String] = [:]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            switch request.kind {
            case .clarify(let clarify):
                ForEach(clarify.questions, id: \.id) { question in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(question.question).font(.headline)
                        if let options = question.options, !options.isEmpty {
                            HStack {
                                ForEach(options, id: \.self) { option in
                                    Button(option) { answers[question.id] = option }
                                        .buttonStyle(.bordered)
                                        .tint(answers[question.id] == option ? .accentColor : nil)
                                }
                            }
                        }
                        TextField("Answer", text: Binding(
                            get: { answers[question.id] ?? "" },
                            set: { answers[question.id] = $0 }))
                    }
                }
                Button("Send Answers") {
                    Task { await model.respond(to: request, with: .answers(answers)) }
                }
                .keyboardShortcut(.defaultAction)

            case .approval(let approval):
                Text("Allow **\(approval.tool)** to run?")
                Text(approval.arguments).font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(6)
                HStack {
                    Button("Deny") { Task { await model.respond(to: request, with: .approved(false)) } }
                    Button("Allow") { Task { await model.respond(to: request, with: .approved(true)) } }
                        .keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background.secondary, in: .rect(cornerRadius: 12))
        .padding(.horizontal, 16).padding(.bottom, 8)
    }
}

extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
