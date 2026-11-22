import KuriAgent
import KuriCore
import KuriSandbox
import KuriStore
import KuriTools
import SwiftUI

/// Transcript and composer for the selected conversation.
///
/// Messages render with Foundation's inline Markdown for now; block-level
/// Markdown (code blocks, lists, tables) is what KuriMarkdown will add.
struct ChatView: View {
    @Environment(AppModel.self) private var model
    @State private var draft = ""
    @State private var choosingFolder = false

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
                    if let id = model.selection, model.compacting.contains(id) {
                        Label {
                            Text("Summarizing earlier messages…")
                        } icon: {
                            ProgressView().controlSize(.small)
                        }
                        .font(.callout).foregroundStyle(.secondary)
                    } else if !model.isSelectedRunning, let turn = model.lastTurn {
                        TurnEndBar(turn: turn)
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

            FolderBar()

            composer
        }
        .navigationTitle(model.selectedConversation?.title.nilIfEmpty ?? "Kuri")
        .toolbar { modelPicker }
        .fileImporter(isPresented: $choosingFolder, allowedContentTypes: [.folder], allowsMultipleSelection: true) { result in
            if case .success(let urls) = result { Task { await model.attach(urls) } }
        }
    }

    private var composer: some View {
        HStack(alignment: .bottom, spacing: 10) {
            TextField("Message Kuri…", text: $draft, axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(1...8)
                .onSubmit(send)
            if model.isSelectedBusy {
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
            Button("Attach Folder", systemImage: "folder.badge.plus") { choosingFolder = true }
                .help("Let Kuri work in a folder: it's mounted in the sandbox at /work")
        }
        ToolbarItem {
            ContextMeter()
        }
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

        case .compaction(let compaction):
            DisclosureGroup {
                Text(compaction.summary)
                    .font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
            } label: {
                Label("Earlier messages summarized", systemImage: "arrow.down.right.and.arrow.up.left")
            }
            .font(.callout).foregroundStyle(.secondary)

        default:
            EmptyView()
        }
    }

    static func inlineMarkdown(_ text: String) -> AttributedString {
        (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(text)
    }
}

/// The folders attached to the conversation, above the composer.
private struct FolderBar: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if !model.folders.isEmpty {
            let mounts = SandboxMounts.plan(folders: model.folders, scratch: URL(filePath: "/"))
            VStack(alignment: .leading, spacing: 6) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(Array(zip(model.folders, mounts)), id: \.0.path) { folder, mount in
                            chip(folder, mountedAt: mount.guestPath)
                        }
                    }
                }
                if model.sandboxStatus != .ready {
                    Text("Set up the sandbox in Settings › Sandbox to let Kuri work in these folders.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 16).padding(.bottom, 8)
        }
    }

    private func chip(_ folder: ConversationFolder, mountedAt guestPath: String) -> some View {
        HStack(spacing: 5) {
            Image(systemName: folder.readOnly ? "lock.fill" : "folder.fill")
                .foregroundStyle(.secondary)
            Text(URL(filePath: folder.path).lastPathComponent)
            Text(guestPath).font(.caption.monospaced()).foregroundStyle(.tertiary)
            Button {
                Task { await model.detach(folder) }
            } label: {
                Image(systemName: "xmark").font(.caption2.weight(.bold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Detach")
        }
        .font(.callout)
        .padding(.horizontal, 9).padding(.vertical, 4)
        .background(.background.secondary, in: .capsule)
        .help(folder.path)
        .contextMenu {
            Button(folder.readOnly ? "Allow Changes" : "Make Read-Only") { Task { await model.toggleReadOnly(folder) } }
            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(filePath: folder.path)]) }
            Divider()
            Button("Detach", role: .destructive) { Task { await model.detach(folder) } }
        }
    }
}

/// After a turn that didn't complete: what happened, and a way to go on.
private struct TurnEndBar: View {
    @Environment(AppModel.self) private var model
    let turn: Turn

    var body: some View {
        if let message {
            HStack(spacing: 10) {
                Image(systemName: turn.status == .failed ? "exclamationmark.triangle" : "pause.circle")
                    .foregroundStyle(turn.status == .failed ? .orange : .secondary)
                Text(message)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                Spacer()
                Button("Continue") { Task { await model.continueSelected() } }
                    .help("Let the model pick up where this turn left off")
            }
            .font(.callout)
            .padding(10)
            .background(.background.secondary, in: .rect(cornerRadius: 10))
        }
    }

    private var message: String? {
        switch turn.status {
        case .cancelled: "Stopped."
        case .failed where turn.error == "Interrupted": "Interrupted: Kuri quit during this turn."
        case .failed: turn.error ?? "This turn failed."
        default: nil
        }
    }
}

/// How full the model's context is, and a way to compact it.
private struct ContextMeter: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if let usage = model.contextUsage {
            Menu {
                Button("Compact Conversation", systemImage: "arrow.down.right.and.arrow.up.left") {
                    Task { await model.compactSelected() }
                }
                .disabled(model.isSelectedBusy)
            } label: {
                HStack(spacing: 6) {
                    if let window = usage.window {
                        Gauge(value: min(Double(usage.tokens) / Double(window), 1)) {}
                            .gaugeStyle(.accessoryCircularCapacity)
                            .scaleEffect(0.45)
                            .frame(width: 18, height: 18)
                        Text("\(Self.short(usage.tokens)) / \(Self.short(window))")
                    } else {
                        Text("≈ \(Self.short(usage.tokens)) tokens")
                    }
                }
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
            }
            .menuIndicator(.hidden)
            .help(usage.window == nil
                ? "Estimated context size. Set contextWindow for this model in config.json to compact automatically."
                : "Estimated context size. Kuri summarizes earlier messages at 75%.")
        }
    }

    static func short(_ tokens: Int) -> String {
        tokens < 1_000 ? "\(tokens)" : String(format: "%.1fk", Double(tokens) / 1_000)
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
