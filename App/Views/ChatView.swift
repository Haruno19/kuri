import KuriAgent
import KuriCore
import KuriSandbox
import KuriStore
import KuriTools
import SwiftUI

/// The new-chat page or the selected conversation, with the composer.
///
/// Messages render with Foundation's inline Markdown for now; block-level
/// Markdown (code blocks, lists, tables) is the first item of the UI roadmap.
struct ChatView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.palette) private var palette
    @State private var draft = ""
    @State private var choosingFolder = false
    @Namespace private var space

    var body: some View {
        ZStack {
            palette.background.ignoresSafeArea()
            if showsWelcome {
                Welcome(composer: composer)
                    .transition(.opacity)
            } else {
                Transcript(composer: composer)
                    // A fresh scroll view per conversation, anchored at its end.
                    .id(model.selection)
                    .transition(.opacity)
            }
        }
        .animation(Tune.move, value: showsWelcome)
        .fileImporter(isPresented: $choosingFolder, allowedContentTypes: [.folder], allowsMultipleSelection: true) { result in
            if case .success(let urls) = result { Task { await model.attach(urls) } }
        }
    }

    private var showsWelcome: Bool {
        model.selection == nil || (model.items.isEmpty && !model.isSelectedRunning)
    }

    private var composer: some View {
        Composer(draft: $draft, choosingFolder: $choosingFolder)
            .matchedGeometryEffect(id: "composer", in: space)
    }
}

// MARK: - Welcome

/// The logo and a greeting on one row, above the composer, a little above
/// the middle of the window.
private struct Welcome<C: View>: View {
    let composer: C
    @Environment(\.palette) private var palette

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            // The greeting's baseline sits a little above the logo's bottom.
            HStack(alignment: .lastTextBaseline, spacing: 16) {
                Logo(size: 46)
                    .alignmentGuide(.lastTextBaseline) { $0[.bottom] - 7 }
                Text(greeting)
                    .font(Typeface.serif(30))
                    .foregroundStyle(palette.ink)
            }
            .padding(.leading, 18)
            .transition(.asymmetric(insertion: .opacity,
                                    removal: .opacity.combined(with: .scale(scale: 0.96, anchor: .leading)).combined(with: .offset(y: -12))))
            FolderBar()
            composer
        }
        .frame(maxWidth: 740)
        .padding(.horizontal, 48)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .offset(x: 12, y: -20)
    }

    private var greeting: String {
        let name = NSFullUserName().split(separator: " ").first.map(String.init) ?? ""
        let hour = Calendar.current.component(.hour, from: .now)
        let part = hour < 5 ? "Still up" : hour < 12 ? "Good morning" : hour < 18 ? "Good afternoon" : "Good evening"
        return name.isEmpty ? "\(part)." : "\(part), \(name)."
    }
}

// MARK: - Transcript

private struct Transcript<C: View>: View {
    let composer: C
    @Environment(AppModel.self) private var model
    @Environment(\.palette) private var palette
    /// The height between the top margin and the composer.
    @State private var visible: CGFloat = 0

    /// From the window's top edge to where a pinned message starts.
    static var topMargin: CGFloat { 56 }
    /// How far the bottom frost rises above the composer.
    static var bottomRise: CGFloat { 32 }

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
                        live
                    }
                    .frame(minHeight: visible, alignment: .top)
                    .id(current.first?.id)
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
                guard let id, current.first?.isUserMessage == true else { return }
                // Next pass, once the new exchange (and its height) is laid out.
                DispatchQueue.main.async {
                    withAnimation(Tune.scroll) { proxy.scrollTo(id, anchor: .top) }
                }
            }
            .safeAreaInset(edge: .bottom) {
                VStack(spacing: 8) {
                    ForEach(model.inputRequests.filter { $0.conversationID == model.selection }) { request in
                        InputRequestView(request: request)
                    }
                    // The inspector's Tasks section has it when that's open.
                    if !model.showsInspector { TaskListPanel(entries: model.taskList) }
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

    /// What the running turn is doing, below the latest messages.
    @ViewBuilder private var live: some View {
        if !model.streamingReasoning.isEmpty && model.streamingText.isEmpty {
            LiveReasoning(text: model.streamingReasoning, room: visible)
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
            Working(status: "Summarizing earlier messages")
                .padding(.horizontal, 6)
        } else if model.isSelectedRunning && model.streamingText.isEmpty {
            Working(status: status)
                .padding(.horizontal, 6)
                .transition(.opacity.combined(with: .offset(y: 6)))
        } else if !model.isSelectedRunning, let turn = model.lastTurn {
            TurnEndBar(turn: turn)
        }
    }

    private var status: String { TranscriptRow.workingStatus(model.items) }

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

    /// The working indicator's words: the tool in progress, or thinking.
    static func workingStatus(_ items: [Item]) -> String {
        if let last = rows(from: items).last, case .tool(_, let call, nil) = last {
            switch call.name {
            case "shell": return "Running a command"
            case "conversation_search": return "Searching past conversations"
            case "memory": return "Updating memory"
            case "clarify": return "Waiting for your answer"
            default: return "Using \(call.name.replacingOccurrences(of: "__", with: " › "))"
            }
        }
        return "Thinking"
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
                .help("Answer again, replacing this answer")
            }
        }
        .font(Typeface.sans(12))
        .foregroundStyle(palette.faint)
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
                    insertion: .scale(scale: 0.98, anchor: .bottom).combined(with: .opacity).combined(with: .offset(y: 16)),
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
    let title: String
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
                .foregroundStyle(palette.faint)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            if open {
                content.transition(.opacity.combined(with: .offset(y: -4)))
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

    var body: some View {
        HStack(spacing: 12 * scale) {
            OrbitingDots().scaleEffect(scale)
            TimelineView(.animation) { context in
                let t = context.date.timeIntervalSinceReferenceDate
                let p = t.truncatingRemainder(dividingBy: Tune.shimmer) / Tune.shimmer * 1.8 - 0.4
                Text(status)
                    .font(Typeface.sans(15 * scale))
                    .foregroundStyle(LinearGradient(stops: [
                        .init(color: palette.faint, location: 0),
                        .init(color: palette.faint, location: clamp(p - 0.25)),
                        .init(color: palette.secondary, location: clamp(p)),
                        .init(color: palette.faint, location: clamp(p + 0.25)),
                        .init(color: palette.faint, location: 1),
                    ], startPoint: .leading, endPoint: .trailing))
            }
            .id(status)
            .transition(.push(from: .bottom).combined(with: .opacity))
        }
        .animation(Tune.status, value: status)
    }

    private func clamp(_ x: Double) -> Double { min(1, max(0, x)) }
}

struct OrbitingDots: View {
    @Environment(\.palette) private var palette

    var body: some View {
        TimelineView(.animation) { context in
            let t = context.date.timeIntervalSinceReferenceDate
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
    }
}

/// Text scrolling up past the pinned message blurs and fades into the
/// background instead of being cut at the window's edge.
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
            .foregroundStyle(palette.faint)
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
/// clearing over the last `fade` points.
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

/// Frosted, a step darker than the background, floating just above it.
/// Controls blend into it; only send/stop stands out.
private struct Composer: View {
    @Binding var draft: String
    @Binding var choosingFolder: Bool
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
                .padding(.horizontal, 5)
            HStack(spacing: 0) {
                QuietButton(glyph: .folder) { choosingFolder = true }
                    .help("Let Kuri work in a folder: it's mounted in the sandbox at /work")
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

    /// While a turn runs, sending queues the message for its next step.
    private func send() {
        let text = draft
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        draft = ""
        Task { await model.send(text) }
    }
}

private struct ModelPicker: View {
    @Environment(AppModel.self) private var model
    @Environment(\.palette) private var palette

    var body: some View {
        Menu {
            ForEach(model.models, id: \.self) { ref in
                Button(ref.description) { Task { await model.setModel(ref) } }
            }
        } label: {
            HStack(spacing: 5) {
                Text(model.composerModel?.model ?? "No model")
                    .foregroundStyle(palette.ink.opacity(0.85))
                PencilIcon(glyph: .chevron, size: 11, color: palette.secondary)
            }
            .font(Typeface.sans(13))
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .modifier(HoverWash())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(model.composerModel?.description ?? "Choose a model")
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
                            .transition(.scale(scale: 0.5).combined(with: .opacity))
                    } else {
                        PencilIcon(glyph: .arrowUp, size: 16 * k, color: ready ? .white : palette.background.opacity(0.9), weight: 1.7)
                            .transition(.scale(scale: 0.5).combined(with: .opacity))
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
    }
}

/// How full the model's context is, and a way to compact it.
private struct ContextMeter: View {
    @Environment(AppModel.self) private var model
    @Environment(\.palette) private var palette

    var body: some View {
        if let usage = model.contextUsage, model.selection != nil {
            Menu {
                Button("Compact Conversation") { Task { await model.compactSelected() } }
                    .disabled(model.isSelectedBusy)
            } label: {
                Text(usage.window.map { "\(Self.short(usage.tokens)) / \(Self.short($0))" } ?? "≈ \(Self.short(usage.tokens))")
                    .font(Typeface.sans(12).monospacedDigit())
                    .foregroundStyle(palette.faint)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .modifier(HoverWash())
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            .help(usage.window == nil
                ? "Estimated context size. Set contextWindow for this model in config.json to compact automatically."
                : "Estimated context size. Kuri summarizes earlier messages at 75%.")
        }
    }

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
                Text("Queued").font(Typeface.sans(12)).foregroundStyle(palette.faint)
                Text(message.text).font(Typeface.sans(13)).foregroundStyle(palette.secondary).lineLimit(2)
                Spacer()
                Button { Task { await model.unqueue(message) } } label: {
                    PencilIcon(glyph: .xmark, size: 12, color: palette.faint).padding(4).modifier(HoverWash())
                }
                .buttonStyle(Squish())
                .help("Remove from the queue")
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
                        .font(Typeface.sans(12)).foregroundStyle(palette.faint)
                }
            }
            .padding(.horizontal, 6)
        }
    }

    private func chip(_ folder: ConversationFolder, mountedAt guestPath: String) -> some View {
        HStack(spacing: 6) {
            PencilIcon(glyph: .folder, size: 13, color: palette.secondary)
            Text(URL(filePath: folder.path).lastPathComponent).foregroundStyle(palette.ink.opacity(0.85))
            Text(guestPath + (folder.readOnly ? " · read-only" : ""))
                .font(Typeface.mono(11)).foregroundStyle(palette.faint)
            Button { Task { await model.detach(folder) } } label: {
                PencilIcon(glyph: .xmark, size: 11, color: palette.faint)
            }
            .buttonStyle(Squish())
            .help("Detach")
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
                    .foregroundStyle(turn.status == .failed ? palette.accent : palette.secondary)
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
        case .cancelled: "Stopped."
        case .failed where turn.error == "Interrupted": "Interrupted: Kuri quit during this turn."
        case .failed: turn.error ?? "This turn failed."
        default: nil
        }
    }
}

/// The current plan, pinned above the composer while it has open tasks.
private struct TaskListPanel: View {
    let entries: [TaskListTool.Entry]
    @Environment(\.palette) private var palette
    @State private var expanded = true

    var body: some View {
        if !entries.isEmpty, entries.contains(where: { $0.status != .completed }) {
            let done = entries.filter { $0.status == .completed }.count
            VStack(alignment: .leading, spacing: 8) {
                Button {
                    withAnimation(Tune.move) { expanded.toggle() }
                } label: {
                    HStack(spacing: 6) {
                        Text("Plan").foregroundStyle(palette.ink)
                        Text("\(done)/\(entries.count)").foregroundStyle(palette.faint).monospacedDigit()
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

extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
