import KuriStore
import SwiftUI

struct MainView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model

        NavigationSplitView {
            List(selection: $model.selection) {
                ForEach(model.conversations) { conversation in
                    ConversationRow(conversation: conversation,
                                    isRunning: model.running.contains(conversation.id),
                                    isAwaitingInput: model.isAwaitingInput(conversation.id))
                        .tag(conversation.id)
                        .contextMenu {
                            Button("Delete", role: .destructive) {
                                Task { await model.delete(conversation.id) }
                            }
                        }
                }
            }
            .navigationSplitViewColumnWidth(min: 200, ideal: 240)
            .toolbar {
                Button("New Conversation", systemImage: "square.and.pencil") {
                    Task { await model.newConversation() }
                }
                .keyboardShortcut("n")
            }
        } detail: {
            switch model.phase {
            case .starting:
                ProgressView()
            case .failed(let message):
                ContentUnavailableView("Kuri couldn't start", systemImage: "exclamationmark.triangle",
                                       description: Text(message))
            case .ready:
                ChatView()
            }
        }
        .alert("Something went wrong", isPresented: Binding(
            get: { model.errorMessage != nil },
            set: { if !$0 { model.errorMessage = nil } })
        ) {
            Button("OK") { model.errorMessage = nil }
        } message: {
            Text(model.errorMessage ?? "")
        }
    }
}

private struct ConversationRow: View {
    let conversation: Conversation
    let isRunning: Bool
    let isAwaitingInput: Bool

    var body: some View {
        HStack {
            Text(conversation.title.isEmpty ? "New Conversation" : conversation.title)
                .lineLimit(1)
            Spacer()
            if isAwaitingInput {
                Image(systemName: "questionmark.bubble.fill")
                    .foregroundStyle(.tint)
                    .help("Waiting for your answer")
            } else if isRunning {
                ProgressView().controlSize(.small)
            }
        }
    }
}
