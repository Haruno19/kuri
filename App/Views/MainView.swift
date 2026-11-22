import KuriStore
import SwiftUI

/// The standard macOS sidebar (collapsed at launch) and the chat. The
/// toolbar is there but invisible: macOS draws its sidebar toggle next to
/// the traffic lights, and nothing else shows above the content.
struct MainView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.palette) private var palette
    @State private var columns: NavigationSplitViewVisibility = .detailOnly

    var body: some View {
        NavigationSplitView(columnVisibility: $columns) {
            Sidebar()
                .navigationSplitViewColumnWidth(min: 240, ideal: 290, max: 380)
        } detail: {
            Group {
                switch model.phase {
                case .starting:
                    palette.background
                case .failed(let message):
                    VStack(spacing: 8) {
                        Text("Kuri couldn't start").font(Typeface.serif(22)).foregroundStyle(palette.ink)
                        Text(message).font(Typeface.sans(13)).foregroundStyle(palette.secondary).textSelection(.enabled)
                    }
                    .padding(40)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(palette.background)
                case .ready:
                    ChatView()
                }
            }
            // Only the top: the content stays beside the sidebar, so the chat
            // shifts right when it opens instead of sliding under it.
            .ignoresSafeArea(edges: .top)
        }
        .toolbar(removing: .title)
        .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
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

/// New chat above the list, a size up from the conversations.
private struct Sidebar: View {
    @Environment(AppModel.self) private var model
    @Environment(\.palette) private var palette

    var body: some View {
        @Bindable var model = model
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
        .listStyle(.sidebar)
        .safeAreaInset(edge: .top, spacing: 4) {
            Button { model.selection = nil } label: {
                HStack(spacing: 8) {
                    PencilIcon(glyph: .compose, size: 17, color: palette.ink)
                    Text("New chat").font(Typeface.sans(14.5)).foregroundStyle(palette.ink)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .modifier(HoverWash(shape: RoundedRectangle(cornerRadius: 8, style: .continuous)))
            }
            .buttonStyle(Squish())
            .keyboardShortcut("n")
            .padding(.horizontal, 10)
        }
    }
}

private struct ConversationRow: View {
    let conversation: Conversation
    let isRunning: Bool
    let isAwaitingInput: Bool
    @Environment(\.palette) private var palette

    var body: some View {
        HStack(spacing: 6) {
            Text(conversation.title.isEmpty ? "New chat" : conversation.title)
                .font(Typeface.sans(13))
                .lineLimit(1)
            Spacer(minLength: 0)
            if isAwaitingInput {
                Circle().strokeBorder(palette.accent, lineWidth: 1.5)
                    .frame(width: 8, height: 8)
                    .help("Waiting for your answer")
            } else if isRunning {
                Orb().help("Working")
            }
        }
    }
}
