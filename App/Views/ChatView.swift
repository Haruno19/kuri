import KuriAgent
import KuriCore
import KuriSandbox
import KuriStore
import KuriTools
import SwiftUI

/// The new-chat page or the selected conversation, with the composer.
struct ChatView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.palette) private var palette
    @State private var draft = ""
    /// The meadow's tree: a new one each window, the same one while it's open.
    @State private var meadowSeed = UInt64.random(in: 0 ... .max)
    @Namespace private var space

    var body: some View {
        ZStack {
            palette.background.ignoresSafeArea()
            if showsWelcome {
                DotGrid()
                    .ignoresSafeArea()
                    .transition(.opacity)
                if model.config.meadow ?? true {
                    Meadowland(seed: meadowSeed)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                        .ignoresSafeArea(edges: .bottom)
                        .transition(.opacity)
                }
                Welcome(composer: composer)
                    .transition(.opacity)
                StatusLine(aboveMeadow: model.config.meadow ?? true)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                    .ignoresSafeArea(edges: .bottom)
                    .transition(.opacity)
            } else {
                Transcript(composer: composer)
                    // A fresh scroll view per conversation, anchored at its
                    // end, made once its items have loaded.
                    .id(model.loadedConversation)
                    .transition(.opacity)
            }
        }
        .animation(Tune.move, value: showsWelcome)
        .fileImporter(isPresented: Bindable(model).choosingFolder, allowedContentTypes: [.folder], allowsMultipleSelection: true) { result in
            if case .success(let urls) = result { Task { await model.attach(urls) } }
        }
    }

    private var showsWelcome: Bool {
        model.selection == nil || (model.items.isEmpty && !model.isSelectedRunning)
    }

    private var composer: some View {
        Composer(draft: $draft)
            // With Reduce Motion, the composer fades into place instead.
            .matchedGeometryEffect(id: "composer", in: space, isSource: !Motion.reduced)
    }
}

// MARK: - Welcome

/// The logo and a greeting on one row, above the composer, a little above
/// the middle of the window.
private struct Welcome<C: View>: View {
    let composer: C
    @Environment(\.palette) private var palette

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            // The greeting's baseline sits just above the logo's bottom.
            HStack(alignment: .lastTextBaseline, spacing: 14) {
                Logo(size: 40)
                    .alignmentGuide(.lastTextBaseline) { $0[.bottom] - 2 }
                Text(greeting)
                    .font(Typeface.serif(30))
                    .foregroundStyle(palette.ink)
            }
            .padding(.leading, 6)
            .transition(.asymmetric(insertion: .opacity,
                                    removal: .moving(.opacity.combined(with: .scale(scale: 0.96, anchor: .leading)).combined(with: .offset(y: -12)))))
            FolderBar()
            composer
        }
        .frame(maxWidth: 740)
        .padding(.horizontal, 48)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .offset(x: 12, y: -20)
    }

    /// Whole sentences, so each language can place the name its own way.
    private var greeting: String {
        let name = NSFullUserName().split(separator: " ").first.map(String.init) ?? ""
        let hour = Calendar.current.component(.hour, from: .now)
        if name.isEmpty {
            return hour < 5 ? String(localized: "Still up?")
                : hour < 12 ? String(localized: "Good morning.")
                : hour < 18 ? String(localized: "Good afternoon.")
                : String(localized: "Good evening.")
        }
        return hour < 5 ? String(localized: "Still up, \(name)?")
            : hour < 12 ? String(localized: "Good morning, \(name).")
            : hour < 18 ? String(localized: "Good afternoon, \(name).")
            : String(localized: "Good evening, \(name).")
    }
}

/// Faint square dots behind the new chat page, like graph paper or an old
/// desktop pattern: clearest around the greeting, gone by the edges. Drawn
/// once per size, one path for every dot.
private struct DotGrid: View {
    /// On the meadow's 4-point grid, so dots and pixels line up.
    static let spacing: CGFloat = 24
    static let dot: CGFloat = 2
    static let opacityDark = 0.13
    static let opacityLight = 0.11
    /// Where the pattern is clearest, as a share of the page, and how far
    /// it reaches, as a share of the page's larger side.
    static let centre = UnitPoint(x: 0.5, y: 0.44)
    static let reach = 0.62
    @Environment(\.palette) private var palette

    var body: some View {
        Canvas { context, size in
            var dots = Path()
            let s = Self.spacing
            // From the bottom left, where the meadow's grid starts.
            var y = size.height - s / 2
            while y > 0 {
                var x = s / 2
                while x < size.width {
                    dots.addRect(CGRect(x: x - Self.dot / 2, y: y - Self.dot / 2, width: Self.dot, height: Self.dot))
                    x += s
                }
                y -= s
            }
            context.fill(dots, with: .color(palette.ink.opacity(palette.dark ? Self.opacityDark : Self.opacityLight)))
        }
        .mask {
            GeometryReader { geometry in
                RadialGradient(colors: [.black, .black.opacity(0.4), .clear], center: Self.centre, startRadius: 0,
                               endRadius: max(geometry.size.width, geometry.size.height) * Self.reach)
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// What the app is up to, in a word or two at the bottom left, the way old
/// software kept a status bar: “Ready” most of the time.
private struct StatusLine: View {
    /// Clear of the meadow's grass when it's there.
    let aboveMeadow: Bool
    @Environment(AppModel.self) private var model
    @Environment(\.palette) private var palette

    var body: some View {
        Text(text)
            .font(Typeface.mono(11))
            .foregroundStyle(palette.dim)
            .contentTransition(.opacity)
            .animation(Tune.status, value: text)
            .padding(.leading, 20)
            .padding(.bottom, aboveMeadow ? 30 : 16)
            .allowsHitTesting(false)
            .accessibilityLabel(Text("Status: \(text)"))
    }

    private var text: String {
        switch model.phase {
        case .starting: return String(localized: "Starting…")
        case .failed: return String(localized: "Not ready")
        case .ready:
            let others = model.running.count
            if others > 0 { return String(localized: "Working in \(others) chats") }
            return model.models.isEmpty ? String(localized: "No model set up") : String(localized: "Ready")
        }
    }
}

// MARK: - Transcript

private struct Transcript<C: View>: View {
    let composer: C
    @Environment(AppModel.self) private var model
    /// The height between the top margin and the composer.
    @State private var visible: CGFloat = 0
    /// When this conversation's transcript appeared: only a message sent
    /// after it scrolls the view, so opening a chat never scrolls it up.
    @State private var appeared = Date.now

    /// From the window's top edge to where a pinned message starts.
    static var topMargin: CGFloat { 56 }
    /// How far the bottom frost rises above the composer.
    static var bottomRise: CGFloat { 32 }
    /// Between the top frost and a pinned message, so the frost never
    /// touches it.
    static var pinGap: CGFloat { 10 }

    var body: some View {
        // The latest exchange (the last user message and what follows) is at
        // least as tall as the visible area, so a sent message can scroll to
        // the top and the reply grows below it.
        let rows = TranscriptRow.rows(from: model.items)
        let split = rows.lastIndex(where: \.isUserMessage) ?? 0
        let current = Array(rows[split...])
        let footers = answerFooters
        ScrollViewReader { proxy in
            ScrollView {
                // Lazy: only what's near the visible area is built. Eager, a
                // long conversation kept every message's text layers alive
                // (about 5 MB per Markdown-heavy answer).
                LazyVStack(alignment: .leading, spacing: 22) {
                    ForEach(rows[..<split]) { row in
                        TranscriptRowView(row: row, isLive: false, footer: footers[row.id])
                    }
                    VStack(alignment: .leading, spacing: 22) {
                        ForEach(current) { row in
                            TranscriptRowView(row: row, isLive: model.isSelectedRunning, footer: footers[row.id])
                        }
                        LiveTail(room: visible)
                    }
                    // The room left once the bottom padding is counted, so at
                    // rest the message sits just under the top frost.
                    .frame(minHeight: max(0, visible - Self.bottomRise - Self.pinGap), alignment: .top)
                    // Scrolled to, the message lands the same way: the
                    // target reaches `pinGap` above it.
                    .padding(.top, Self.pinGap)
                    .id(current.first?.id)
                    .padding(.top, -Self.pinGap)
                }
                .frame(maxWidth: 740)
                .padding(.horizontal, 48)
                // At rest, the last line clears the frost above the composer.
                .padding(.bottom, Self.bottomRise)
                .frame(maxWidth: .infinity)
            }
            .defaultScrollAnchor(.bottom)
            .safeAreaPadding(.top, Self.topMargin)
            .onScrollGeometryChange(for: CGFloat.self) { geometry in
                // Already without the top margin and the composer.
                geometry.containerSize.height
            } action: { _, height in
                visible = max(0, height)
            }
            .onChange(of: current.first?.id) { _, id in
                // A message sent now, below the end of the chat: scrolling
                // to it only ever goes down.
                guard let id, case .item(let message)? = current.first, current.first?.isUserMessage == true,
                      message.createdAt >= appeared else { return }
                // Next pass, once the new exchange (and its height) is laid out.
                DispatchQueue.main.async {
                    withAnimation(Tune.scroll) { proxy.scrollTo(id, anchor: .top) }
                }
            }
            .safeAreaInset(edge: .bottom) {
                VStack(spacing: 8) {
                    // First: open, it floats up over the transcript, and
                    // nothing else in the stack may be under it.
                    TaskListPanel()
                    ForEach(model.inputRequests.filter { $0.conversationID == model.selection }) { request in
                        InputRequestView(request: request)
                    }
                    QueuedMessages()
                    FolderBar()
                    composer
                }
                .frame(maxWidth: 740)
                .padding(.horizontal, 48)
                .padding(.bottom, 18)
                .frame(maxWidth: .infinity)
                // The same frost as the top edge, behind the composer and
                // rising a little above it.
                .background {
                    EdgeFade(edge: .bottom, fade: Self.bottomRise + 12)
                        .padding(.top, -Self.bottomRise)
                }
            }
            .overlay(alignment: .top) {
                EdgeFade(edge: .top).frame(height: Self.topMargin)
            }
        }
    }

    /// The status line goes under each finished turn's last reply; only
    /// the latest one can be retried.
    private var answerFooters: [UUID: AnswerFooter] {
        var last: [UUID: UUID] = [:]  // turn → its last assistant message
        for item in model.items {
            if case .message(let message) = item.payload, message.role == .assistant, let turn = item.turnID {
                last[turn] = item.id
            }
        }
        var footers: [UUID: AnswerFooter] = [:]
        for (turnID, itemID) in last {
            guard let turn = model.turns[turnID], turn.endedAt != nil else { continue }
            let latest = turnID == model.lastTurn?.id && !model.isSelectedRunning
            footers[itemID] = AnswerFooter(turn: turn, canRetry: latest)
        }
        return footers
    }

}

/// What the running turn is doing, below the latest messages. A view of its
/// own, so a streamed token redraws this and not the whole transcript.
struct LiveTail: View {
    /// The visible height of the transcript, for the reasoning window.
    let room: CGFloat
    @Environment(AppModel.self) private var model
    @Environment(\.palette) private var palette

    var body: some View {
        if !model.streamingReasoning.isEmpty && model.streamingText.isEmpty {
            LiveReasoning(text: model.streamingReasoning, room: room)
                .padding(.horizontal, 6)
        }
        if !model.streamingText.isEmpty {
            ReplyText(text: model.streamingText)
        }
        if let id = model.selection, let notice = model.fallbackNotices[id] {
            Text(notice)
                .font(Typeface.sans(13))
                .foregroundStyle(palette.secondary)
                .padding(.horizontal, 6)
        }
        if let id = model.selection, model.compacting.contains(id) {
            Working(status: String(localized: "Summarizing earlier messages"))
                .padding(.horizontal, 6)
        } else if model.isSelectedRunning && model.streamingText.isEmpty {
            Working(status: model.workingStatus)
                .padding(.horizontal, 6)
                .transition(.moving(.opacity.combined(with: .offset(y: 6))))
        } else if !model.isSelectedRunning, let turn = model.lastTurn {
            TurnEndBar(turn: turn)
        }
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

    var isUserMessage: Bool {
        if case .item(let item) = self, case .message(let message) = item.payload { message.role == .user } else { false }
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

struct TranscriptRowView: View {
    let row: TranscriptRow
    let isLive: Bool
    var footer: AnswerFooter?

    var body: some View {
        switch row {
        case .tool(_, let call, let result):
            ToolCallView(call: call, result: result, isLive: isLive)
                .padding(.horizontal, 6)
        case .item(let item):
            VStack(alignment: .leading, spacing: 8) {
                ItemView(payload: item.payload)
                if let footer { footer.transition(.opacity) }
            }
        }
    }
}

/// Under a finished answer: when it ended and what it cost, dim and small
/// like the context meter; the latest answer can be retried.
struct AnswerFooter: View {
    let turn: Turn
    let canRetry: Bool
    @Environment(AppModel.self) private var model
    @Environment(\.palette) private var palette
    @State private var showsSplit = false

    var body: some View {
        HStack(spacing: 10) {
            Text(time)
            if total > 0 {
                // Hovering splits the count into what went in and came out.
                Text(showsSplit
                     ? "\(Self.count(turn.usage.inputTokens)) tok in · \(Self.count(turn.usage.outputTokens)) tok out"
                     : "\(Self.count(total)) tok")
                    .monospacedDigit()
                    .contentTransition(.opacity)
                    .onHover { hovering in withAnimation(Tune.hover) { showsSplit = hovering } }
                    // The split, without hovering: as a tooltip and to VoiceOver.
                    .help("\(Self.count(turn.usage.inputTokens)) tokens in, \(Self.count(turn.usage.outputTokens)) out")
                    .accessibilityLabel(Text("\(Self.count(turn.usage.inputTokens)) tokens in, \(Self.count(turn.usage.outputTokens)) out"))
            }
            Spacer()
            if canRetry {
                Button { Task { await model.retrySelected() } } label: {
                    HStack(spacing: 4) {
                        PencilIcon(glyph: .retry, size: 12, color: palette.faint)
                        Text("Retry")
                    }
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .modifier(HoverWash())
                }
                .buttonStyle(Squish())
                .help("Answer again, replacing this answer (⌘R)")
            }
        }
        .font(Typeface.sans(12))
        .foregroundStyle(palette.dim)
        .padding(.horizontal, 6)
    }

    private var total: Int { turn.usage.inputTokens + turn.usage.outputTokens }

    private var time: String {
        let date = turn.endedAt ?? turn.startedAt
        return Calendar.current.isDateInToday(date)
            ? date.formatted(date: .omitted, time: .shortened)
            : date.formatted(.dateTime.day().month(.abbreviated).hour().minute())
    }

    private static func count(_ tokens: Int) -> String { tokens.formatted(.number) }
}

struct ItemView: View {
    let payload: Item.Payload
    @Environment(\.palette) private var palette
    @Environment(\.chatScale) private var scale

    var body: some View {
        switch payload {
        case .message(let message) where message.role == .user:
            Text(message.text)
                .font(Typeface.sans(15.5 * scale))
                .lineSpacing(3 * scale)
                .foregroundStyle(palette.ink)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16 * scale)
                .padding(.vertical, 12 * scale)
                .modifier(Pane())
                .transition(.asymmetric(
                    insertion: .moving(.scale(scale: 0.98, anchor: .bottom).combined(with: .opacity).combined(with: .offset(y: 16))),
                    removal: .opacity))

        case .message(let message):
            ReplyText(text: message.text)

        case .reasoning(let reasoning) where !reasoning.text.isEmpty:
            Folded(title: "Thought") {
                Text(reasoning.text)
                    .font(Typeface.sans(13 * scale))
                    .foregroundStyle(palette.secondary)
                    .lineSpacing(2)
                    .textSelection(.enabled)
            }
            .padding(.horizontal, 6)

        case .compaction(let compaction):
            Folded(title: "Earlier messages summarized") {
                Text(compaction.summary)
                    .font(Typeface.sans(13 * scale))
                    .foregroundStyle(palette.secondary)
                    .lineSpacing(2)
                    .textSelection(.enabled)
            }
            .padding(.horizontal, 6)

        default:
            EmptyView()
        }
    }
}

/// A model reply: Markdown, serif, straight on the surface.
struct ReplyText: View {
    let text: String
    @Environment(\.chatScale) private var scale

    var body: some View {
        MarkdownView(text: text, size: 15 * scale)
            .padding(.horizontal, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A quiet line that opens to show more: reasoning, summaries.
struct Folded<Content: View>: View {
    let title: LocalizedStringKey
    @ViewBuilder let content: Content
    @Environment(\.palette) private var palette
    @Environment(\.chatScale) private var scale
    @State private var open = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                withAnimation(Tune.move) { open.toggle() }
            } label: {
                HStack(spacing: 5) {
                    Text(title).font(Typeface.sans(13 * scale))
                    PencilIcon(glyph: .chevron, size: 11 * scale, color: palette.faint)
                        .rotationEffect(.degrees(open ? 0 : -90))
                }
                .foregroundStyle(palette.dim)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityValue(open ? Text("Expanded") : Text("Collapsed"))
            if open {
                content.transition(.moving(.opacity.combined(with: .offset(y: -4))))
            }
        }
    }
}

/// What the model is doing: three dots circling in depth, and the status
/// with light slowly crossing it.
struct Working: View {
    let status: String
    @Environment(\.palette) private var palette
    @Environment(\.chatScale) private var scale
    @Environment(\.accessibilityReduceMotion) private var still

    var body: some View {
        HStack(spacing: 12 * scale) {
            OrbitingDots().scaleEffect(scale)
            // With Reduce Motion the light doesn't cross: plain text.
            TimelineView(.animation(paused: still)) { context in
                let t = context.date.timeIntervalSinceReferenceDate
                let p = still ? -1 : t.truncatingRemainder(dividingBy: Tune.shimmer) / Tune.shimmer * 1.8 - 0.4
                Text(status)
                    .font(Typeface.sans(15 * scale))
                    .foregroundStyle(LinearGradient(stops: [
                        .init(color: palette.dim, location: 0),
                        .init(color: palette.dim, location: clamp(p - 0.25)),
                        .init(color: palette.secondary, location: clamp(p)),
                        .init(color: palette.dim, location: clamp(p + 0.25)),
                        .init(color: palette.dim, location: 1),
                    ], startPoint: .leading, endPoint: .trailing))
            }
            .id(status)
            .transition(.moving(.push(from: .bottom).combined(with: .opacity)))
        }
        .animation(Tune.status, value: status)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(status))
        .accessibilityAddTraits(.updatesFrequently)
    }

    private func clamp(_ x: Double) -> Double { min(1, max(0, x)) }
}

struct OrbitingDots: View {
    @Environment(\.palette) private var palette
    @Environment(\.accessibilityReduceMotion) private var still

    var body: some View {
        // Still with Reduce Motion: the three dots resting in a row.
        TimelineView(.animation(paused: still)) { context in
            let t = still ? 0 : context.date.timeIntervalSinceReferenceDate
            ZStack {
                ForEach(0..<3) { i in
                    let a = t * 2.4 + Double(i) * 2 * .pi / 3
                    let depth = (sin(a) + 1) / 2  // 0 far, 1 near
                    Circle()
                        .fill(RadialGradient(colors: [palette.accentLight, palette.accent],
                                             center: UnitPoint(x: 0.35, y: 0.3), startRadius: 0, endRadius: 6))
                        .frame(width: 7, height: 7)
                        .scaleEffect(0.65 + 0.45 * depth)
                        .opacity(0.4 + 0.6 * depth)
                        .offset(x: cos(a) * 9, y: sin(a) * 3)
                        .zIndex(depth)
                }
            }
            .frame(width: 28, height: 20)
            .rotationEffect(.degrees(-10))
        }
        .accessibilityHidden(true)
    }
}

/// Reasoning as it streams: a window of its latest lines, at most ten or
/// about a third of the room between the pinned message and the composer;
/// older lines fade out at the top.
struct LiveReasoning: View {
    let text: String
    /// The visible height of the transcript.
    let room: CGFloat
    @Environment(\.palette) private var palette
    @Environment(\.chatScale) private var scale
    @State private var height: CGFloat = 0

    private static let lineHeight: CGFloat = 19
    private static let maxLines: CGFloat = 10
    private static let minLines: CGFloat = 4
    private static let roomShare: CGFloat = 0.3

    var body: some View {
        let line = Self.lineHeight * scale
        let cap = min(Self.maxLines * line, max(Self.minLines * line, room * Self.roomShare))
        let overflows = height > cap + 0.5
        Text(text)
            .font(Typeface.sans(13 * scale))
            .foregroundStyle(palette.dim)
            .lineSpacing(2)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height = $0 }
            // The newest line stays at the bottom; the rest is cut off above.
            .frame(height: overflows ? cap : nil, alignment: .bottom)
            .clipped()
            .mask {
                LinearGradient(stops: [.init(color: overflows ? .clear : .black, location: 0),
                                       .init(color: .black, location: overflows ? 0.4 : 0)],
                               startPoint: .top, endPoint: .bottom)
            }
            .animation(Tune.status, value: overflows)
    }
}

/// Frosts the transcript where it meets a window edge: solid at the edge,
/// clearing over the last `fade` points, so text scrolling past the pinned
/// message fades into the background instead of being cut.
struct EdgeFade: View {
    let edge: VerticalEdge
    var fade: CGFloat = 36
    @Environment(\.palette) private var palette

    var body: some View {
        GeometryReader { geometry in
            let solid = max(0, 1 - fade / max(geometry.size.height, 1))
            ZStack {
                Rectangle().fill(.ultraThinMaterial)
                palette.background.opacity(0.75)
            }
            .mask(LinearGradient(stops: [.init(color: .black, location: 0), .init(color: .black, location: solid), .init(color: .clear, location: 1)],
                                 startPoint: edge == .top ? .top : .bottom, endPoint: edge == .top ? .bottom : .top))
        }
        .allowsHitTesting(false)
    }
}

// MARK: - Composer

/// Return sends; Shift-Return breaks the line instead. The field editor
/// inserts the newline at the cursor, as it does for Option-Return.
struct ShiftReturnBreaksLine: ViewModifier {
    func body(content: Content) -> some View {
        content.onKeyPress(.return, phases: .down) { press in
            guard press.modifiers.contains(.shift) else { return .ignored }
            NSApp.sendAction(#selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)), to: nil, from: nil)
            return .handled
        }
    }
}

/// Frosted, a step darker than the background, floating just above it.
/// Controls blend into it; only send/stop stands out.
private struct Composer: View {
    @Binding var draft: String
    @Environment(AppModel.self) private var model
    @Environment(\.palette) private var palette
    @FocusState private var focused: Bool

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
        VStack(alignment: .leading, spacing: 8) {
            TextField("Ask anything", text: $draft, axis: .vertical)
                .textFieldStyle(.plain)
                .font(Typeface.sans(14.5))
                .foregroundStyle(palette.ink)
                .lineLimit(1...8)
                .focused($focused)
                .onSubmit(send)
                .modifier(ShiftReturnBreaksLine())
                .padding(.horizontal, 5)
            HStack(spacing: 0) {
                QuietButton(glyph: .folder, name: "Attach Folder") { model.choosingFolder = true }
                    .help("Let Kuri work in a folder: it's mounted in the sandbox at /work (⇧⌘O)")
                Spacer()
                ContextMeter()
                ModelPicker()
                SendButton(draft: draft, send: send)
                    .padding(.leading, 4)
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 13)
        .padding(.bottom, 9)
        .background {
            // Liquid Glass brightens what's under it (lighter than the
            // surface in dark mode); a tinted fill over a blur keeps the
            // composer a step darker.
            ZStack {
                shape.fill(.ultraThinMaterial)
                shape.fill(palette.composer.opacity(0.88))
                shape.strokeBorder(palette.ink.opacity(palette.dark ? 0.06 : 0.05), lineWidth: 1)
            }
        }
        .background { OuterShadow(shape: shape, color: palette.shadow.opacity(palette.dark ? 0.35 : 0.07), radius: 14, y: 6) }
        .background { OuterShadow(shape: shape, color: palette.shadow.opacity(palette.dark ? 0.3 : 0.05), radius: 1, y: 1) }
        .onAppear { focused = true }
    }

    private func send() { model.submit(&draft) }
}

/// The conversation's model, or on the new-chat page the one it will
/// start with. Small and dim in the mini window, over its composer.
struct ModelPicker: View {
    var small = false
    @Environment(AppModel.self) private var model
    @Environment(\.palette) private var palette

    var body: some View {
        Menu {
            ForEach(model.models, id: \.self) { ref in
                Button(ref.description) { Task { await model.setModel(ref) } }
            }
        } label: {
            HStack(spacing: small ? 4 : 5) {
                Text(model.composerModel?.model ?? String(localized: "No model"))
                    .lineLimit(1)
                    .foregroundStyle(small ? palette.dim : palette.ink.opacity(0.85))
                PencilIcon(glyph: .chevron, size: small ? 9 : 11, color: small ? palette.faint : palette.secondary)
            }
            .font(Typeface.sans(small ? 11.5 : 13))
            .padding(.horizontal, small ? 5 : 9)
            .padding(.vertical, small ? 3 : 5)
            .modifier(HoverWash(shape: RoundedRectangle(cornerRadius: small ? 6 : 7, style: .continuous)))
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(model.composerModel?.description ?? String(localized: "Choose a model"))
    }
}

/// Send, or stop while a turn runs and there's nothing to queue. The
/// coloured layer fades in over a flat disabled base.
struct SendButton: View {
    let draft: String
    let send: () -> Void
    var size: CGFloat = 30
    @Environment(AppModel.self) private var model
    @Environment(\.palette) private var palette

    var body: some View {
        let hasText = !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let stops = model.isSelectedBusy && !hasText
        let ready = hasText || stops
        let k = size / 30
        Button {
            if stops { Task { await model.cancel() } } else { send() }
        } label: {
            ZStack {
                RoundedRectangle(cornerRadius: 8 * k, style: .continuous).fill(palette.faint.opacity(0.28))
                ZStack {
                    RoundedRectangle(cornerRadius: 8 * k, style: .continuous).fill(palette.accentFill)
                    RoundedRectangle(cornerRadius: 8 * k, style: .continuous)
                        .strokeBorder(LinearGradient(colors: [.white.opacity(0.35), .clear], startPoint: .top, endPoint: .center), lineWidth: 1)
                }
                .shadow(color: palette.shadow.opacity(palette.dark ? 0.4 : 0.12), radius: 2, y: 1)
                .opacity(ready ? 1 : 0)
                ZStack {
                    if stops {
                        RoundedRectangle(cornerRadius: 2.5 * k, style: .continuous)
                            .fill(.white)
                            .frame(width: 10 * k, height: 10 * k)
                            .transition(.moving(.scale(scale: 0.5).combined(with: .opacity)))
                    } else {
                        PencilIcon(glyph: .arrowUp, size: 16 * k, color: ready ? .white : palette.background.opacity(0.9), weight: 1.7)
                            .transition(.moving(.scale(scale: 0.5).combined(with: .opacity)))
                    }
                }
            }
            .frame(width: size, height: size)
            .animation(Tune.move, value: stops)
            .animation(Tune.enable, value: ready)
        }
        .buttonStyle(Squish())
        .keyboardShortcut(stops ? "." : .return, modifiers: stops ? .command : [])
        .help(stops ? "Stop (⌘.)" : model.isSelectedBusy ? "Queue: joins the turn at its next step" : "Send")
        .accessibilityLabel(stops ? Text("Stop") : model.isSelectedBusy ? Text("Queue") : Text("Send"))
    }
}

/// How full the model's context is, and a way to compact it.
private struct ContextMeter: View {
    @Environment(AppModel.self) private var model
    @Environment(\.palette) private var palette

    var body: some View {
        if let usage = model.contextUsage, model.selection != nil {
            Menu {
                Button("Compact Chat") { Task { await model.compactSelected() } }
                    .disabled(model.isSelectedBusy)
            } label: {
                Text(usage.window.map { "\(TokenCount.short(usage.tokens)) / \(TokenCount.short($0))" } ?? "≈ \(TokenCount.short(usage.tokens))")
                    .font(Typeface.sans(12).monospacedDigit())
                    .foregroundStyle(palette.dim)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .modifier(HoverWash())
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            .accessibilityLabel(Text("Context"))
            .help(usage.window == nil
                ? "Estimated context size. Set contextWindow for this model in config.json to compact automatically."
                : "Estimated context size. Kuri summarizes earlier messages at \(Int(model.config.compactionThreshold * 100))%.")
        }
    }
}

/// Token counts the way the composer and the inspector show them.
enum TokenCount {
    static func short(_ tokens: Int) -> String {
        tokens < 1_000 ? "\(tokens)" : String(format: "%.1fk", Double(tokens) / 1_000)
    }
}

// MARK: - Above the composer

/// Messages waiting for the running turn's next step.
private struct QueuedMessages: View {
    @Environment(AppModel.self) private var model
    @Environment(\.palette) private var palette

    var body: some View {
        ForEach(model.selectedQueue) { message in
            HStack(spacing: 8) {
                Text("Queued").font(Typeface.sans(12)).foregroundStyle(palette.dim)
                Text(message.text).font(Typeface.sans(13)).foregroundStyle(palette.secondary).lineLimit(2)
                Spacer()
                Button { Task { await model.unqueue(message) } } label: {
                    PencilIcon(glyph: .xmark, size: 12, color: palette.faint).padding(8).modifier(HoverWash())
                }
                .buttonStyle(Squish())
                .help("Remove from the queue")
                .accessibilityLabel(Text("Remove from the Queue"))
            }
            .padding(.horizontal, 12)
            .help("Joins the turn at its next step")
        }
    }
}

/// The folders attached to the conversation, above the composer.
private struct FolderBar: View {
    @Environment(AppModel.self) private var model
    @Environment(\.palette) private var palette

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
                    .padding(.horizontal, 2)
                }
                if model.sandboxStatus != .ready {
                    Text("Set up the sandbox in Settings › Sandbox to let Kuri work in these folders.")
                        .font(Typeface.sans(12)).foregroundStyle(palette.dim)
                }
            }
            .padding(.horizontal, 6)
        }
    }

    private func chip(_ folder: ConversationFolder, mountedAt guestPath: String) -> some View {
        HStack(spacing: 6) {
            PencilIcon(glyph: .folder, size: 13, color: palette.secondary)
            Text(URL(filePath: folder.path).lastPathComponent).foregroundStyle(palette.ink.opacity(0.85))
            Text(folder.readOnly ? String(localized: "\(guestPath) · read-only") : guestPath)
                .font(Typeface.mono(11)).foregroundStyle(palette.dim)
            Button { Task { await model.detach(folder) } } label: {
                // A 20-point target around the small cross.
                PencilIcon(glyph: .xmark, size: 11, color: palette.faint)
                    .frame(width: 20, height: 20)
                    .contentShape(.rect)
            }
            .buttonStyle(Squish())
            .padding(.vertical, -3)
            .help("Detach")
            .accessibilityLabel(Text("Detach \(URL(filePath: folder.path).lastPathComponent)"))
        }
        .font(Typeface.sans(13))
        .padding(.horizontal, 10).padding(.vertical, 5)
        .modifier(Pane(radius: 7))
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
struct TurnEndBar: View {
    @Environment(AppModel.self) private var model
    @Environment(\.palette) private var palette
    @Environment(\.chatScale) private var scale
    let turn: Turn

    var body: some View {
        if let message {
            HStack(spacing: 10) {
                Text(message)
                    .foregroundStyle(turn.status == .failed ? palette.accentText : palette.secondary)
                    .textSelection(.enabled)
                Spacer()
                Button("Continue") { Task { await model.continueSelected() } }
                    .buttonStyle(Squish())
                    .foregroundStyle(palette.ink)
                    .padding(.horizontal, 10).padding(.vertical, 4)
                    .modifier(HoverWash())
                    .help("Let the model pick up where this turn left off")
            }
            .font(Typeface.sans(13 * scale))
            .padding(.horizontal, 12 * scale).padding(.vertical, 8 * scale)
            .modifier(Pane())
        }
    }

    private var message: String? {
        switch turn.status {
        case .cancelled: String(localized: "Stopped.")
        case .failed where turn.error == "Interrupted": String(localized: "Interrupted: Kuri quit during this turn.")
        case .failed: turn.error ?? String(localized: "This turn failed.")
        default: nil
        }
    }
}

/// The current plan, above the composer while it has open tasks (the
/// inspector's Tasks section has it when that's open). Only its folded
/// height takes room in the column: open, it floats up over the transcript,
/// so folding and unfolding it never lays the transcript out again.
private struct TaskListPanel: View {
    @Environment(AppModel.self) private var model
    @State private var expanded = true

    var body: some View {
        let entries = model.taskList
        if !model.planInInspector, entries.contains(where: { $0.status != .completed }) {
            PlanCard(entries: entries, expanded: false) {}
                .hidden()
                .overlay(alignment: .bottom) {
                    PlanCard(entries: entries, expanded: expanded) {
                        withAnimation(Tune.move) { expanded.toggle() }
                    }
                    // Its own height, growing upwards from the folded slot.
                    .fixedSize(horizontal: false, vertical: true)
                }
                .transition(.opacity)
        }
    }
}

private struct PlanCard: View {
    let entries: [TaskListTool.Entry]
    let expanded: Bool
    let toggle: () -> Void
    @Environment(\.palette) private var palette

    var body: some View {
        let done = entries.filter { $0.status == .completed }.count
        VStack(alignment: .leading, spacing: 8) {
            Button(action: toggle) {
                HStack(spacing: 6) {
                    Text("Plan").foregroundStyle(palette.ink)
                    Text("\(done)/\(entries.count)").foregroundStyle(palette.dim).monospacedDigit()
                    Spacer()
                    PencilIcon(glyph: .chevron, size: 11, color: palette.faint)
                        .rotationEffect(.degrees(expanded ? 0 : -90))
                }
                .font(Typeface.sans(13))
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            if expanded {
                TaskListRows(entries: entries)
                    .transition(.opacity)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .modifier(Pane())
    }
}

struct InputRequestView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.palette) private var palette
    let request: InputRequest
    @Environment(\.chatScale) private var scale
    @State private var answers: [String: String] = [:]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            switch request.kind {
            case .clarify(let clarify):
                ForEach(clarify.questions, id: \.id) { question in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(question.question).font(Typeface.serif(15 * scale)).foregroundStyle(palette.ink)
                        if let options = question.options, !options.isEmpty {
                            HStack {
                                ForEach(options, id: \.self) { option in
                                    Button(option) { answers[question.id] = option }
                                        .buttonStyle(.bordered)
                                        .tint(answers[question.id] == option ? palette.accent : nil)
                                }
                            }
                        }
                        TextField("Answer", text: Binding(
                            get: { answers[question.id] ?? "" },
                            set: { answers[question.id] = $0 }))
                            .textFieldStyle(.plain)
                            .font(Typeface.sans(14 * scale))
                    }
                }
                Button("Send Answers") {
                    Task { await model.respond(to: request, with: .answers(answers)) }
                }
                .keyboardShortcut(.defaultAction)

            case .approval(let approval):
                Text("Allow **\(approval.tool)** to run?").font(Typeface.serif(15 * scale)).foregroundStyle(palette.ink)
                Text(approval.arguments).font(Typeface.mono(11.5 * scale)).foregroundStyle(palette.secondary).lineLimit(6)
                HStack {
                    Button("Deny") { Task { await model.respond(to: request, with: .approved(false)) } }
                        .keyboardShortcut(.cancelAction)
                    Button("Allow") { Task { await model.respond(to: request, with: .approved(true)) } }
                        .keyboardShortcut(.defaultAction)
                }
            }
        }
        .font(Typeface.sans(13 * scale))
        .padding(14 * scale)
        .frame(maxWidth: .infinity, alignment: .leading)
        .modifier(Pane())
    }
}
