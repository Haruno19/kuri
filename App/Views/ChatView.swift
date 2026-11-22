import KuriAgent
import KuriCore
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
                    ForEach(model.items) { item in
                        ItemView(payload: item.payload)
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

        case .toolCall(let call):
            Label(call.name, systemImage: "wrench.and.screwdriver")
                .font(.callout.monospaced()).foregroundStyle(.secondary)

        case .toolResult(let result):
            DisclosureGroup(result.isError ? "Tool error" : "Result") {
                Text(result.output).font(.caption.monospaced()).textSelection(.enabled)
            }
            .font(.caption).foregroundStyle(result.isError ? .red : .secondary)

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
