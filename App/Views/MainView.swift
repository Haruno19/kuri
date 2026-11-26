import KuriStore
import SwiftUI

/// The standard macOS sidebar (collapsed at launch), the chat, and the
/// inspector on the right (closed at launch). The toolbar is there but
/// invisible and empty; the two toggles are Kuri's own, a matching pair in
/// the chat's top corners.
struct MainView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.palette) private var palette
    /// Where the window's traffic lights are, to sit the toggles beside them.
    @State private var lights = TrafficLights()

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
                case .inUse(let message, let kuri):
                    InUseView(message: message, kuri: kuri)
                case .ready:
                    ChatView()
                }
            }
            // Both toggles are drawn by the chat, a matching pair in its top
            // corners, so they stay put in full screen too (where macOS hides
            // toolbar items until the pointer reaches the top). The
            // sidebar's sits just past the traffic lights, or just outside
            // the open sidebar; the inspector's mirrors it on the right.
            .overlay(alignment: .top) {
                HStack(spacing: 0) {
                    PaneToggle(symbol: "sidebar.left",
                               label: model.showsSidebar ? "Hide Sidebar" : "Show Sidebar",
                               help: model.showsSidebar ? "Hide the sidebar (⌃⌘S)" : "Show the sidebar (⌃⌘S)") {
                        model.showsSidebar.toggle()
                    }
                    .padding(.leading, model.showsSidebar ? PaneToggle.inset
                             : max(PaneToggle.inset, lights.trailing + PaneToggle.afterLights))
                    Spacer(minLength: 0)
                    if model.phase.isReady {
                        PaneToggle(symbol: "sidebar.right",
                                   label: model.showsInspector ? "Hide Inspector" : "Show Inspector",
                                   help: model.showsInspector ? "Hide the inspector (⌥⌘I)" : "Show the inspector (⌥⌘I)") {
                            model.toggleInspector()
                        }
                        .padding(.trailing, PaneToggle.inset)
                    }
                }
                // Never past the window's top edge, even if the title bar
                // comes out shorter than the circles.
                .padding(.top, max(PaneToggle.top, lights.midY.map { $0 - PaneToggle.size / 2 } ?? PaneToggle.top))
                .animation(Tune.move, value: model.showsSidebar)
            }
            .background(TrafficLightsReader { lights = $0 })
            // An empty toolbar item: with no item at all macOS drops the
            // toolbar, the title bar shrinks to 28 points and the traffic
            // lights rise above where the toggles fit. This keeps the
            // unified title bar's height, and the lights level with them. In
            // the middle, away from the toggles: the toolbar sits above the
            // content, and an item over a toggle would take its clicks.
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Color.clear.frame(width: 1, height: 1)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
                .sharedBackgroundVisibility(.hidden)
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
        // In full screen macOS draws the toolbar in a window of its own,
        // opaque whatever its background says: a band across the top that
        // hides the chat's and the inspector's tops. It slides in with the
        // menu bar instead, and the content reaches the screen's top edge.
        .windowToolbarFullScreenVisibility(.onHover)
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

/// Another client has the home folder, and only one runs at a time
/// (decision 0028): try again once it's quit, or, when it's kuri in a
/// terminal, quit it from here.
private struct InUseView: View {
    let message: String
    let kuri: Int32?
    @Environment(AppModel.self) private var model
    @Environment(\.palette) private var palette
    @State private var confirming = false
    /// The message wraps under the title rather than across the window.
    static let messageWidth: CGFloat = 460

    var body: some View {
        VStack(spacing: 8) {
            Text(kuri == nil ? "Kuri is already running" : "kuri is running in a terminal")
                .font(Typeface.serif(22)).foregroundStyle(palette.ink)
            Text(message).font(Typeface.sans(13)).foregroundStyle(palette.secondary).textSelection(.enabled)
                .multilineTextAlignment(.center)
                .frame(maxWidth: Self.messageWidth)
            HStack(spacing: 10) {
                if kuri != nil {
                    Button { confirming = true } label: {
                        label(model.quittingKuri ? "Quitting kuri…" : "Quit kuri…")
                    }
                    .buttonStyle(PrimaryButton())
                    .disabled(model.quittingKuri)
                }
                Button { Task { await model.start() } } label: { label("Try Again") }
                    .buttonStyle(SecondaryButton())
                    .disabled(model.quittingKuri)
            }
            .padding(.top, 14)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(palette.background)
        .confirmationDialog("Quit kuri?", isPresented: $confirming) {
            Button("Quit kuri") {
                if let kuri { Task { await model.quitKuri(kuri) } }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Whatever it's doing in its terminal stops, as if you'd quit it there.")
        }
    }

    private func label(_ title: LocalizedStringKey) -> some View {
        Text(title).font(Typeface.sans(13.5))
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
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
            // Both marks on one centre line, clear of the row's edge.
            if isAwaitingInput {
                Circle().strokeBorder(palette.accent, lineWidth: 1.5)
                    .frame(width: 8, height: 8)
                    .frame(width: 12, height: 12)
                    .padding(.trailing, 4)
                    .help("Waiting for your answer")
            } else if isRunning {
                Bead().help("Working")
                    .padding(.trailing, 4)
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

/// Where the window's traffic lights are, in the content's coordinates
/// (top-left origin): their trailing edge, and the line through their
/// centres. Empty in full screen, where there are none.
struct TrafficLights: Equatable {
    var trailing: CGFloat = 0
    var midY: CGFloat?
}

/// Reads `TrafficLights` from the window it's in, again when the window
/// enters or leaves full screen or changes size.
struct TrafficLightsReader: NSViewRepresentable {
    let changed: (TrafficLights) -> Void

    func makeNSView(context: Context) -> ReaderView {
        let view = ReaderView()
        view.changed = changed
        return view
    }

    func updateNSView(_ view: ReaderView, context: Context) { view.changed = changed }

    final class ReaderView: NSView {
        var changed: ((TrafficLights) -> Void)?
        private var last: TrafficLights?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            NotificationCenter.default.removeObserver(self)
            guard let window else { return }
            for name in [NSWindow.didEnterFullScreenNotification, NSWindow.didExitFullScreenNotification,
                         NSWindow.didResizeNotification] {
                NotificationCenter.default.addObserver(self, selector: #selector(windowChanged), name: name, object: window)
            }
            // Once the title bar has laid its buttons out.
            DispatchQueue.main.async { [weak self] in self?.report() }
        }

        @objc private func windowChanged() { report() }

        private func report() {
            guard let window else { return }
            var lights = TrafficLights()
            if !window.styleMask.contains(.fullScreen),
               let zoom = window.standardWindowButton(.zoomButton), !zoom.isHidden, zoom.window === window {
                // Window coordinates have their origin at the bottom left.
                let frame = zoom.convert(zoom.bounds, to: nil)
                lights = TrafficLights(trailing: frame.maxX, midY: window.frame.height - frame.midY)
            }
            guard lights != last else { return }
            last = lights
            changed?(lights)
        }
    }
}
