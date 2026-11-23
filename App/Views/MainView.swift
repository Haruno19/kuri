import KuriStore
import SwiftUI

/// The standard macOS sidebar (collapsed at launch), the chat, and the
/// inspector on the right (closed at launch). The toolbar is there but
/// invisible; the two toggles are Kuri's own, a matching pair in the
/// chat's top corners.
struct MainView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.palette) private var palette
    @State private var columns: NavigationSplitViewVisibility = .detailOnly
    /// Where the sidebar toggle sits while the sidebar is closed: just past
    /// the traffic lights, where macOS put its own.
    static let trafficLights: CGFloat = 96

    var body: some View {
        @Bindable var model = model
        NavigationSplitView(columnVisibility: $columns) {
            Sidebar()
                // Kuri draws its own, outside the sidebar.
                .toolbar(removing: .sidebarToggle)
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
            // The two panes' toggles, drawn by the chat so they stay outside
            // both: macOS would put its own sidebar toggle inside the open
            // sidebar, and a toolbar button over the inspector.
            .overlay(alignment: .topLeading) {
                PaneToggle(glyph: .sidebar, help: columns == .detailOnly ? "Show the sidebar (⌃⌘S)" : "Hide the sidebar (⌃⌘S)") {
                    columns = columns == .detailOnly ? .all : .detailOnly
                }
                // Past the traffic lights while the sidebar is closed.
                .padding(.leading, columns == .detailOnly ? Self.trafficLights : PaneToggle.inset)
                .padding(.top, PaneToggle.top)
            }
            .overlay(alignment: .topTrailing) {
                if model.phase.isReady {
                    PaneToggle(glyph: .inspector, help: model.showsInspector ? "Hide the inspector (⌥⌘I)" : "Show the inspector (⌥⌘I)") {
                        model.showsInspector.toggle()
                    }
                    .padding(.trailing, PaneToggle.inset)
                    .padding(.top, PaneToggle.top)
                }
            }
            // Only the top: the content stays beside the sidebar, so the chat
            // shifts right when it opens instead of sliding under it.
            .ignoresSafeArea(edges: .top)
            .inspector(isPresented: $model.showsInspector) {
                InspectorView()
                    .inspectorColumnWidth(min: 270, ideal: 320, max: 460)
            }
        }
        .toolbar(removing: .title)
        // An empty toolbar collapses, and the traffic lights move up out of
        // line with the toggles: an invisible item keeps its height.
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Color.clear.frame(width: 1, height: 1).accessibilityHidden(true)
            }
            .sharedBackgroundVisibility(.hidden)
        }
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
    /// The conversation whose title is being edited in place.
    @State private var renaming: UUID?

    var body: some View {
        @Bindable var model = model
        List(selection: $model.selection) {
            ForEach(model.conversations) { conversation in
                ConversationRow(conversation: conversation,
                                isRunning: model.running.contains(conversation.id),
                                isAwaitingInput: model.isAwaitingInput(conversation.id),
                                renaming: Binding(
                                    get: { renaming == conversation.id },
                                    set: { if !$0, renaming == conversation.id { renaming = nil } }))
                    .tag(conversation.id)
                    .simultaneousGesture(TapGesture(count: 2).onEnded { renaming = conversation.id })
                    .contextMenu {
                        Button("Rename") { renaming = conversation.id }
                        Button("Delete", role: .destructive) {
                            Task { await model.delete(conversation.id) }
                        }
                    }
            }
        }
        .listStyle(.sidebar)
        // Return renames the selected chat, as in Finder.
        .onKeyPress(.return) {
            guard renaming == nil, let id = model.selection else { return .ignored }
            renaming = id
            return .handled
        }
        .safeAreaInset(edge: .top, spacing: 16) {
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
    @Environment(AppModel.self) private var model
    let conversation: Conversation
    let isRunning: Bool
    let isAwaitingInput: Bool
    @Binding var renaming: Bool
    @Environment(\.palette) private var palette
    @State private var draft = ""
    @FocusState private var focused: Bool

    private var title: String { conversation.title.isEmpty ? "New chat" : conversation.title }

    var body: some View {
        HStack(spacing: 6) {
            if renaming {
                // Return or clicking away saves; Escape keeps the old title.
                TextField("Title", text: $draft)
                    .textFieldStyle(.plain)
                    .font(Typeface.sans(13))
                    .focused($focused)
                    .onSubmit(commit)
                    .onExitCommand { renaming = false }
                    .onAppear {
                        draft = title
                        focused = true
                    }
                    .onChange(of: focused) { _, isFocused in if !isFocused { commit() } }
            } else {
                Text(title)
                    .font(Typeface.sans(13))
                    .lineLimit(1)
            }
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

private extension ConversationRow {
    func commit() {
        guard renaming else { return }
        renaming = false
        let id = conversation.id, text = draft
        Task { await model.rename(id, to: text) }
    }
}
