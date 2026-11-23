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

/// New chat (the primary action) and Settings above the list.
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
        .safeAreaInset(edge: .top, spacing: 8) {
            VStack(spacing: 6) {
                Button { model.selection = nil } label: {
                    SidebarButtonLabel(glyph: .compose, title: "New chat", color: .white)
                }
                .buttonStyle(PrimaryButton())
                .keyboardShortcut("n")

                SettingsLink {
                    SidebarButtonLabel(glyph: .sliders, title: "Settings", color: palette.ink)
                }
                .buttonStyle(SecondaryButton())
            }
            .padding(.horizontal, 10)
            .padding(.top, 2)
        }
    }
}

private struct SidebarButtonLabel: View {
    let glyph: Glyph
    let title: String
    let color: Color

    var body: some View {
        HStack(spacing: 8) {
            PencilIcon(glyph: glyph, size: 16, color: color, weight: 1.6)
            Text(title).font(Typeface.sans(13.5))
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 6.5)
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
