import KuriStore
import SwiftUI

/// The standard macOS sidebar (collapsed at launch), the chat, and the
/// inspector on the right (closed at launch). The toolbar is there but
/// invisible; the two toggles are Kuri's own, a matching pair in the
/// chat's top corners.
struct MainView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.palette) private var palette

    var body: some View {
        @Bindable var model = model
        NavigationSplitView(columnVisibility: columns) {
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
            // The sidebar's toggle is a toolbar item of the chat's column:
            // macOS keeps it at the column's leading edge, next to the
            // traffic lights or just outside the open sidebar, and moves it
            // with the sidebar. Its own toggle would sit inside the sidebar.
            .toolbar {
                ToolbarItem(placement: .navigation) {
                    PaneToggle(glyph: .sidebar,
                               label: model.showsSidebar ? "Hide Sidebar" : "Show Sidebar",
                               help: model.showsSidebar ? "Hide the sidebar (⌃⌘S)" : "Show the sidebar (⌃⌘S)") {
                        model.showsSidebar.toggle()
                    }
                    // macOS leaves 4 points after the open sidebar; this
                    // makes it the inspector toggle's inset.
                    .padding(.leading, model.showsSidebar ? PaneToggle.inset - 4 : 0)
                    .animation(Tune.move, value: model.showsSidebar)
                }
                .sharedBackgroundVisibility(.hidden)
            }
            // The inspector's is drawn by the chat: as a toolbar item, macOS
            // would put it over the inspector.
            .overlay(alignment: .topTrailing) {
                if model.phase.isReady {
                    PaneToggle(glyph: .inspector,
                               label: model.showsInspector ? "Hide Inspector" : "Show Inspector",
                               help: model.showsInspector ? "Hide the inspector (⌥⌘I)" : "Show the inspector (⌥⌘I)") {
                        model.toggleInspector()
                    }
                    .padding(.trailing, PaneToggle.inset)
                    .padding(.top, PaneToggle.top)
                }
            }
            // Only the top: the content stays beside the sidebar, so the chat
            // shifts right when it opens instead of sliding under it.
            .ignoresSafeArea(edges: .top)
            // Through `toggleInspector()` even when macOS closes it itself.
            .inspector(isPresented: Binding(
                get: { model.showsInspector },
                set: { if $0 != model.showsInspector { model.toggleInspector() } })
            ) {
                InspectorView()
                    .inspectorColumnWidth(min: 270, ideal: 320, max: 460)
            }
        }
        // Not drawn, but the Window menu, Mission Control and VoiceOver
        // name the window by the chat it shows.
        .navigationTitle(model.selectedConversation.map(\.displayTitle) ?? String(localized: "New Chat"))
        .toolbar(removing: .title)
        .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
        .alert(model.problem?.title ?? "", isPresented: Binding(
            get: { model.problem != nil },
            set: { if !$0 { model.problem = nil } }),
            presenting: model.problem
        ) { _ in
            Button("OK") { model.problem = nil }
        } message: { problem in
            Text(problem.message)
        }
        // Deleting a chat can't be undone: its messages and steps go.
        .confirmationDialog(deletionTitle, isPresented: Binding(
            get: { model.pendingDeletion != nil },
            set: { if !$0 { model.pendingDeletion = nil } }),
            presenting: model.pendingDeletion
        ) { id in
            Button("Delete Chat", role: .destructive) {
                model.pendingDeletion = nil
                Task { await model.delete(id) }
            }
            Button("Cancel", role: .cancel) { model.pendingDeletion = nil }
        } message: { _ in
            Text("Its messages and steps are deleted. This can't be undone.")
        }
    }

    /// The split view's columns, from the model's `showsSidebar`.
    private var columns: Binding<NavigationSplitViewVisibility> {
        Binding(get: { model.showsSidebar ? .all : .detailOnly },
                set: { model.showsSidebar = $0 != .detailOnly })
    }

    private var deletionTitle: String {
        let title = model.conversations.first { $0.id == model.pendingDeletion }?.displayTitle ?? ""
        return String(localized: "Delete “\(title)”?")
    }
}

extension Conversation {
    /// The title, or a placeholder until it has one.
    var displayTitle: String { title.isEmpty ? String(localized: "New Chat") : title }
}

extension AppModel {
    /// Shows or hides the inspector, for its button, View › Show Inspector
    /// and ⌥⌘I alike. The plan above the composer hides (or comes back) only
    /// once the slide is over: changing the composer area's height during
    /// it would lay the transcript out again at every frame of the slide.
    func toggleInspector() {
        withAnimation(Tune.move, completionCriteria: .logicallyComplete) {
            showsInspector.toggle()
        } completion: { [self] in
            guard planInInspector != showsInspector else { return }
            withAnimation(Tune.fade) { planInInspector = showsInspector }
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
                                isAwaitingInput: model.isAwaitingInput(conversation.id),
                                renaming: Binding(
                                    get: { model.renaming == conversation.id },
                                    set: { if !$0, model.renaming == conversation.id { model.renaming = nil } }))
                    .tag(conversation.id)
                    .simultaneousGesture(TapGesture(count: 2).onEnded { model.renaming = conversation.id })
                    .contextMenu {
                        Button("Rename Chat") { model.renaming = conversation.id }
                        Divider()
                        Button("Delete Chat…", role: .destructive) { model.pendingDeletion = conversation.id }
                    }
            }
        }
        .listStyle(.sidebar)
        // Return renames the selected chat, as in Finder.
        .onKeyPress(.return) {
            guard model.renaming == nil, let id = model.selection else { return .ignored }
            model.renaming = id
            return .handled
        }
        // Delete asks first, as Chat › Delete Chat… does.
        .onDeleteCommand {
            guard model.renaming == nil, let id = model.selection else { return }
            model.pendingDeletion = id
        }
        .safeAreaInset(edge: .top, spacing: 16) {
            VStack(spacing: 6) {
                Button { model.selection = nil } label: {
                    SidebarButtonLabel(glyph: .compose, title: "New Chat", color: .white)
                }
                .buttonStyle(PrimaryButton())
                .help("Start a new chat (⌘N)")

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
    let title: LocalizedStringKey
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

    private var title: String { conversation.displayTitle }

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
        // The dot's meaning, for VoiceOver: it's only drawn.
        .accessibilityElement(children: renaming ? .contain : .combine)
        .accessibilityValue(isAwaitingInput ? Text("Waiting for your answer") : isRunning ? Text("Working") : Text(""))
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
