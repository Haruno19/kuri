import KuriCore
import KuriStore
import SwiftUI

/// The mini window's content: a title bar with the chat picker, the
/// transcript (Markdown without LaTeX, a size down), and a one-line
/// composer at the bottom. Glass all through: the window itself is
/// `NSGlassEffectView`, and panels inside are glass with no fill.
struct MiniChat: View {
    @Environment(AppModel.self) private var model
    @Environment(\.palette) private var palette
    @State private var draft = ""
    @State private var choosingFolder = false

    static let scale: CGFloat = 0.85
    /// The title bar's height, which the traffic lights sit in.
    static let titleBar: CGFloat = 32

    var body: some View {
        VStack(spacing: 0) {
            if showsTranscript {
                MiniTranscript()
                    .id(model.loadedConversation)
                    .transition(.opacity)
            } else {
                Color.clear.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            VStack(alignment: .leading, spacing: 6) {
                ForEach(model.inputRequests.filter { $0.conversationID == model.selection }) { request in
                    InputRequestView(request: request)
                }
                if let message = model.errorMessage {
                    Text(message)
                        .font(Typeface.sans(11.5))
                        .foregroundStyle(palette.accent)
                        .textSelection(.enabled)
                        .onTapGesture { model.errorMessage = nil }
                        .help("Click to dismiss")
                }
                HStack(spacing: 2) {
                    MiniFolderButton(choosingFolder: $choosingFolder)
                    Spacer(minLength: 8)
                    ModelPicker(small: true)
                }
                MiniComposer(draft: $draft)
            }
            .padding(.horizontal, 10)
            .padding(.bottom, 10)
        }
        .padding(.top, Self.titleBar)
        // Over the transcript, not above it in the stack: scroll views reach
        // under the title bar and would take its clicks.
        .overlay(alignment: .top) { MiniTitleBar().zIndex(1) }
        .animation(Tune.move, value: showsTranscript)
        .environment(\.chatScale, Self.scale)
        .environment(\.glassOnly, true)
        .environment(\.allowsMath, false)
        .ignoresSafeArea()
        .fileImporter(isPresented: $choosingFolder, allowedContentTypes: [.folder], allowsMultipleSelection: true) { result in
            if case .success(let urls) = result { Task { await model.attach(urls) } }
        }
    }

    private var showsTranscript: Bool {
        model.selection != nil && (!model.items.isEmpty || model.isSelectedRunning)
    }
}

// MARK: - Title bar

/// The traffic lights on the left (AppKit's), the chat's title on the
/// right; the rest drags the window.
private struct MiniTitleBar: View {
    @Environment(AppModel.self) private var model
    @Environment(\.palette) private var palette
    @State private var picking = false

    var body: some View {
        HStack {
            Spacer(minLength: 72)
            Button { picking.toggle() } label: {
                HStack(spacing: 4) {
                    Text(title)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    PencilIcon(glyph: .chevron, size: 10, color: palette.secondary)
                }
                .font(Typeface.sans(12))
                .foregroundStyle(palette.ink.opacity(0.85))
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .modifier(HoverWash())
            }
            .buttonStyle(Squish())
            .popover(isPresented: $picking, arrowEdge: .bottom) {
                MiniChatList { picking = false }
                    .environment(model)
            }
        }
        .padding(.trailing, 8)
        .frame(height: MiniChat.titleBar)
        .background(Color.clear.contentShape(.rect).gesture(WindowDragGesture()))
        .contextMenu {
            Button("Open Kuri") { MiniController.shared.openInMain() }
        }
    }

    private var title: String {
        guard model.selection != nil else { return "New chat" }
        let title = model.selectedConversation?.title ?? ""
        return title.isEmpty ? "New chat" : title
    }
}

/// New chat, then every chat, scrolling past a few.
private struct MiniChatList: View {
    let done: () -> Void
    @Environment(AppModel.self) private var model
    @Environment(\.palette) private var palette

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 1) {
                row(nil, title: "New chat", glyph: .compose)
                Rectangle().fill(palette.faint.opacity(0.25)).frame(height: 1).padding(.vertical, 4).padding(.horizontal, 6)
                ForEach(model.conversations) { conversation in
                    row(conversation.id, title: conversation.title.isEmpty ? "New chat" : conversation.title, glyph: nil)
                }
            }
            .padding(6)
        }
        .frame(width: 250)
        .frame(maxHeight: 300)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func row(_ id: UUID?, title: String, glyph: Glyph?) -> some View {
        Button {
            model.selection = id
            done()
        } label: {
            HStack(spacing: 7) {
                if let glyph { PencilIcon(glyph: glyph, size: 13, color: palette.ink) }
                Text(title).lineLimit(1)
                Spacer(minLength: 0)
                if let id, model.running.contains(id) { Orb(size: 6) }
            }
            .font(Typeface.sans(12))
            .foregroundStyle(palette.ink)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background {
                if id != nil, id == model.selection {
                    RoundedRectangle(cornerRadius: 6, style: .continuous).fill(palette.wash)
                }
            }
            .modifier(HoverWash(shape: RoundedRectangle(cornerRadius: 6, style: .continuous)))
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Transcript

private struct MiniTranscript: View {
    @Environment(AppModel.self) private var model

    /// How far text fades in below the title bar. The window is glass, so
    /// the main window's frost would show as a band: the text fades out
    /// instead, and nothing reaches the traffic lights.
    static let fade: CGFloat = 26

    var body: some View {
        let rows = TranscriptRow.rows(from: model.items)
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 14) {
                ForEach(rows) { row in
                    TranscriptRowView(row: row, isLive: model.isSelectedRunning)
                }
                LiveTail(room: 300)
            }
            .padding(.horizontal, 12)
            .padding(.top, 10)
            .padding(.bottom, 12)
        }
        .defaultScrollAnchor(.bottom)
        .defaultScrollAnchor(.bottom, for: .sizeChanges)
        .scrollEdgeEffectHidden(true, for: .top)
        // Outside the mask nothing draws, which also keeps scrolled text
        // from reaching up under the title bar.
        .mask {
            VStack(spacing: 0) {
                LinearGradient(colors: [.clear, .black], startPoint: .top, endPoint: .bottom).frame(height: Self.fade)
                Color.black
            }
        }
    }
}

// MARK: - Bottom

/// A folder icon and label, small and dim like the context meter.
private struct MiniFolderButton: View {
    @Binding var choosingFolder: Bool
    @Environment(AppModel.self) private var model
    @Environment(\.palette) private var palette

    var body: some View {
        Group {
            if model.folders.isEmpty {
                Button { choosingFolder = true } label: { label("Folder") }
                    .buttonStyle(Squish())
                    .help("Let Kuri work in a folder: it's mounted in the sandbox at /work")
            } else {
                Menu {
                    ForEach(model.folders, id: \.path) { folder in
                        Button("Detach \(name(folder))") { Task { await model.detach(folder) } }
                    }
                    Divider()
                    Button("Add Folder…") { choosingFolder = true }
                } label: {
                    label(model.folders.map(name).joined(separator: ", "))
                }
                .menuStyle(.button)
                .buttonStyle(.plain)
                .menuIndicator(.hidden)
                .fixedSize()
                .help(model.folders.map(\.path).joined(separator: "\n"))
            }
        }
        .padding(.leading, 2)
    }

    private func label(_ text: String) -> some View {
        HStack(spacing: 4) {
            PencilIcon(glyph: .folder, size: 12, color: palette.faint)
            Text(text).lineLimit(1)
        }
        .font(Typeface.sans(11.5))
        .foregroundStyle(palette.faint)
        .padding(.horizontal, 5)
        .padding(.vertical, 3)
        .modifier(HoverWash(shape: RoundedRectangle(cornerRadius: 6, style: .continuous)))
    }

    private func name(_ folder: ConversationFolder) -> String {
        URL(filePath: folder.path).lastPathComponent
    }
}

/// One line, two at most (then it scrolls), and send/stop.
private struct MiniComposer: View {
    @Binding var draft: String
    @Environment(AppModel.self) private var model
    @Environment(\.palette) private var palette
    @FocusState private var focused: Bool

    var body: some View {
        HStack(alignment: .bottom, spacing: 8) {
            TextField("Ask anything", text: $draft, axis: .vertical)
                .textFieldStyle(.plain)
                .font(Typeface.sans(13))
                .foregroundStyle(palette.ink)
                .lineLimit(1...2)
                .focused($focused)
                .onSubmit(send)
                .modifier(ShiftReturnBreaksLine())
                .padding(.vertical, 4)
            SendButton(draft: draft, send: send, size: 24)
        }
        .padding(.leading, 12)
        .padding(.trailing, 8)
        .padding(.vertical, 5)
        // A step darker than the window's glass, as the main composer is
        // darker than its surface: a translucent shade over the glass (a
        // glass tint alone barely darkens it).
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.black.opacity(palette.dark ? 0.38 : 0.1)))
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .onAppear { focused = true }
    }

    private func send() { model.submit(&draft) }
}
