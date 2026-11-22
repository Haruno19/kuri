// Autumn: a sketch of Kuri's main window, following docs/ui.md.
// A standalone app with fake data, to agree on a direction before touching App/.
//
//   swiftc -parse-as-library -O Sketches/Autumn.swift -o /tmp/autumn && /tmp/autumn
//
// Try: click the logo, send a message (Return), stop it (⌘.), toggle the
// sidebar, switch the theme (top right, or ⇧⌘T). Environment overrides for
// screenshots: AUTUMN_SCHEME=light|dark, AUTUMN_STATE=new|chat, AUTUMN_SIDEBAR=1,
// AUTUMN_SEND="text" (sends it a second after launch).

import AppKit
import SwiftUI

// MARK: - Tuning

/// Every timing in one place: these are what we'll adjust back and forth.
enum Tune {
    /// Things entering, leaving or moving across the window.
    static let move = Animation.spring(response: 0.42, dampingFraction: 0.88)
    /// Scrolling a sent message to the top.
    static let scroll = Animation.spring(response: 0.5, dampingFraction: 0.9)
    /// Status text swapping while the model works.
    static let status = Animation.spring(response: 0.35, dampingFraction: 0.9)
    /// Hover washes and highlights.
    static let hover = Animation.easeOut(duration: 0.14)
    /// Pressed buttons.
    static let press = Animation.spring(response: 0.22, dampingFraction: 0.65)
    /// Seconds for the light to cross the status text once.
    static let shimmer = 3.6
    /// Seconds per word while a fake reply streams.
    static let wordDelay = 0.028
}

// MARK: - Palette and type

/// Quiet, warm neutrals (the flows page's palette) with a muted chestnut accent.
struct Palette {
    let scheme: ColorScheme
    var dark: Bool { scheme == .dark }

    var background: Color { dark ? hex(0x1C1B1A) : hex(0xFAF9F5) }
    /// The composer sits a step darker than the background in both themes.
    var composer: Color { dark ? hex(0x141312) : hex(0xEFEDE6) }

    var ink: Color { dark ? hex(0xECEBE5) : hex(0x1F1E1D) }
    var secondary: Color { dark ? hex(0xA8A59C) : hex(0x6B6A64) }
    var faint: Color { dark ? hex(0x78766F) : hex(0x9C9A92) }

    /// Accent for the send button and the working dots: chestnut, toned down.
    var accent: Color { dark ? hex(0xC08452) : hex(0xA4693D) }
    var accentLight: Color { dark ? hex(0xD6A06F) : hex(0xC18A5B) }
    var accentFill: LinearGradient { LinearGradient(colors: [accentLight, accent], startPoint: .top, endPoint: .bottom) }

    /// The icon's own gradient, for the logo only.
    var iconTop: Color { dark ? Color(.displayP3, red: 0.50, green: 0.31, blue: 0.14) : Color(.displayP3, red: 0.60, green: 0.345, blue: 0.165) }
    var iconBottom: Color { Color(red: 0.733, green: 0.58, blue: 0.341) }
    var iconGradient: LinearGradient { LinearGradient(colors: [iconTop, iconBottom], startPoint: .top, endPoint: .bottom) }

    // User cards: a slab of paper, lighter than the background.
    var cardTop: Color { dark ? hex(0x2B2A28) : hex(0xFFFFFF) }
    var cardBottom: Color { dark ? hex(0x262523) : hex(0xFCFBF8) }
    var cardEdge: Color { dark ? hex(0x121110) : hex(0xE4E1D7) }
    var highlight: Color { .white.opacity(dark ? 0.07 : 0.9) }
    var shadow: Color { dark ? .black : hex(0x3A3226) }

    var wash: Color { ink.opacity(dark ? 0.08 : 0.06) }

    private func hex(_ v: UInt32) -> Color {
        Color(red: Double((v >> 16) & 0xFF) / 255, green: Double((v >> 8) & 0xFF) / 255, blue: Double(v & 0xFF) / 255)
    }
}

struct PaletteKey: EnvironmentKey { static let defaultValue = Palette(scheme: .light) }
extension EnvironmentValues {
    var palette: Palette {
        get { self[PaletteKey.self] }
        set { self[PaletteKey.self] = newValue }
    }
}

/// Placeholders until the author picks the final pair: a humanist serif for
/// the model and accents, a humanist sans for everything else.
enum Typeface {
    static func serif(_ size: CGFloat) -> Font { .custom("Iowan Old Style", size: size) }
    static func sans(_ size: CGFloat) -> Font { .custom("Seravek", size: size) }
}

// MARK: - Fake conversation

@MainActor @Observable final class Chat {
    enum Phase: Equatable { case idle, working(String), streaming }
    struct Message: Identifiable, Equatable {
        let id = UUID()
        let fromUser: Bool
        var text: String
    }

    var messages: [Message] = []
    var phase: Phase = .idle
    var draft = ""
    private var task: Task<Void, Never>?

    var busy: Bool { phase != .idle }

    func send() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !busy else { return }
        withAnimation(Tune.move) {
            messages.append(Message(fromUser: true, text: text))
            draft = ""
            phase = .working("Thinking")
        }
        task = Task { await reply() }
    }

    func stop() {
        task?.cancel()
        withAnimation(Tune.move) { phase = .idle }
    }

    private func reply() async {
        for status in ["Thinking", "Reading the project", "Running swift build"] {
            withAnimation(Tune.status) { phase = .working(status) }
            try? await Task.sleep(for: .seconds(1.4))
            if Task.isCancelled { return }
        }
        withAnimation(Tune.move) {
            phase = .streaming
            messages.append(Message(fromUser: false, text: ""))
        }
        let words = Sample.reply.split(separator: " ", omittingEmptySubsequences: false)
        for (i, word) in words.enumerated() {
            try? await Task.sleep(for: .seconds(Tune.wordDelay))
            if Task.isCancelled { return }
            messages[messages.count - 1].text += (i == 0 ? "" : " ") + word
        }
        withAnimation(Tune.move) { phase = .idle }
    }

    func seed() {
        messages = [
            Message(fromUser: true, text: "The build fails since I moved the sandbox code into its own module. Can you find out why?"),
            Message(fromUser: false, text: Sample.reply),
            Message(fromUser: true, text: "Great, do that. Then run the tests again and tell me if anything else broke."),
        ]
        phase = .working("Running swift test")
    }
}

enum Sample {
    static let reply = """
    The module boundary is fine; the failure comes from one file. `Sandbox.swift` still imports `KuriTools` for a single helper, `ShellQuote`, and the new `KuriSandbox` target doesn't depend on it, so the compiler can't find the type.

    There are two clean ways out. Move `ShellQuote` down into `KuriCore`, where both targets can see it, or give `KuriSandbox` its own small copy. The first keeps one implementation and costs a single file move; I'd go with that.
    """
}

// MARK: - App

@main struct AutumnSketch: App {
    init() {
        NSApplication.shared.setActivationPolicy(.regular)
        setvbuf(stdout, nil, _IOLBF, 0)
    }

    var body: some Scene {
        WindowGroup("Kuri") {
            Root()
                .frame(minWidth: 720, minHeight: 560)
        }
        .windowToolbarStyle(.unified)
        .defaultSize(width: 1040, height: 780)
    }
}

/// Only for the sketch: System, Light, Dark.
enum Theme: String, CaseIterable {
    case system = "System", light = "Light", dark = "Dark"

    var appearance: NSAppearance? {
        switch self {
        case .system: nil
        case .light: NSAppearance(named: .aqua)
        case .dark: NSAppearance(named: .darkAqua)
        }
    }

    var next: Theme { Self.allCases[(Self.allCases.firstIndex(of: self)! + 1) % Self.allCases.count] }
}

struct Root: View {
    @Environment(\.colorScheme) private var scheme
    @State private var chat = Chat()
    @State private var columns: NavigationSplitViewVisibility = .detailOnly
    @State private var theme: Theme = .system
    @Namespace private var space

    var body: some View {
        let palette = Palette(scheme: scheme)
        NavigationSplitView(columnVisibility: $columns) {
            Sidebar()
                .navigationSplitViewColumnWidth(min: 240, ideal: 290, max: 380)
        } detail: {
            ZStack {
                palette.background.ignoresSafeArea()
                if chat.messages.isEmpty {
                    NewChat(space: space).transition(.opacity)
                } else {
                    Conversation(space: space).transition(.opacity)
                }
            }
            .overlay(alignment: .topTrailing) {
                ThemeButton(theme: $theme).padding(.top, 10).padding(.trailing, 14)
            }
            // Only the top: the content stays beside the sidebar, so the
            // chat shifts right when it opens instead of sliding under it.
            .ignoresSafeArea(edges: .top)
        }
        // A toolbar that's there but invisible: macOS draws its standard
        // sidebar and its own sidebar toggle next to the traffic lights,
        // and nothing else shows above the content.
        .toolbar(removing: .title)
        .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
        .environment(\.palette, palette)
        .environment(chat)
        .onChange(of: theme) { _, theme in NSApp.appearance = theme.appearance }
        .onAppear {
            let env = ProcessInfo.processInfo.environment
            theme = Theme(rawValue: (env["AUTUMN_SCHEME"] ?? "").capitalized) ?? .system
            NSApp.appearance = theme.appearance
            if env["AUTUMN_STATE"] == "chat" { chat.seed() }
            if env["AUTUMN_SIDEBAR"] == "1" { columns = .all }
            if let text = env["AUTUMN_SEND"] {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                    chat.stop()
                    chat.draft = text
                    chat.send()
                }
            }
            NSApp.activate()
            // For screenshots: `screencapture -l <number>`.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                if let window = NSApp.windows.first(where: \.isVisible) {
                    print("window \(window.windowNumber)")
                    fflush(stdout)
                }
            }
        }
    }
}

struct ThemeButton: View {
    @Binding var theme: Theme
    @Environment(\.palette) private var palette

    var body: some View {
        Button {
            theme = theme.next
        } label: {
            Text(theme.rawValue)
                .font(Typeface.sans(12.5))
                .foregroundStyle(palette.faint)
                .padding(.horizontal, 9)
                .padding(.vertical, 4)
                .modifier(HoverWash())
        }
        .buttonStyle(Squish())
        .keyboardShortcut("t", modifiers: [.command, .shift])
        .help("Sketch only: switch between system, light and dark (⇧⌘T)")
    }
}

// MARK: - New chat

struct NewChat: View {
    let space: Namespace.ID
    @Environment(\.palette) private var palette

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            HStack(spacing: 16) {
                GlassChestnut(size: 46)
                Text(greeting)
                    .font(Typeface.serif(30))
                    .foregroundStyle(palette.ink)
            }
            .padding(.leading, 4)
            .transition(.asymmetric(insertion: .opacity,
                                    removal: .opacity.combined(with: .scale(scale: 0.96, anchor: .leading)).combined(with: .offset(y: -12))))
            Composer()
                .matchedGeometryEffect(id: "composer", in: space)
        }
        .frame(maxWidth: 740)
        .padding(.horizontal, 48)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .offset(y: -20)
    }

    private var greeting: String {
        let name = NSFullUserName().split(separator: " ").first.map(String.init) ?? ""
        let hour = Calendar.current.component(.hour, from: .now)
        let part = hour < 5 ? "Still up" : hour < 12 ? "Good morning" : hour < 18 ? "Good afternoon" : "Good evening"
        return name.isEmpty ? "\(part)." : "\(part), \(name)."
    }
}

// MARK: - Logo

/// The chestnut from the app icon, in Liquid Glass tinted with the icon's
/// gradient. Still at rest; each click plays one of a few small reactions,
/// never the same twice in a row.
struct GlassChestnut: View {
    let size: CGFloat
    @Environment(\.palette) private var palette
    /// One counter per reaction; bumping one plays it.
    @State private var plays: [Reaction: Int] = [:]
    @State private var last = Reaction.hop

    enum Reaction: CaseIterable {
        /// Squish, jump, land.
        case hop
        /// Two small hops, the second smaller.
        case skip
        /// Shakes its head, like a jelly.
        case wiggle
        /// A jump with a full turn in the air.
        case flip
    }

    struct Pose { var sx = 1.0, sy = 1.0, y = 0.0, r = 0.0 }

    var body: some View {
        let shape = ChestnutShape()
        ZStack {
            Color.clear
                .glassEffect(.regular.tint(palette.iconBottom.opacity(0.3)), in: shape)
            // The icon's gradient, thin enough that the glass shows through.
            shape.fill(palette.iconGradient).opacity(palette.dark ? 0.6 : 0.5)
            // Depth: the glass thickens toward the bottom...
            shape.fill(LinearGradient(colors: [.clear, palette.iconTop.opacity(0.35)], startPoint: .center, endPoint: .bottom))
            // ...and catches the light at the top.
            shape.fill(LinearGradient(colors: [.white.opacity(palette.dark ? 0.18 : 0.35), .clear], startPoint: .top, endPoint: .center))
            shape.stroke(LinearGradient(colors: [.white.opacity(palette.dark ? 0.45 : 0.85), .white.opacity(0.12)],
                                        startPoint: .top, endPoint: .bottom), lineWidth: 1)
        }
        .frame(width: size, height: size)
        .compositingGroup()
        .shadow(color: palette.shadow.opacity(palette.dark ? 0.35 : 0.1), radius: 4, y: 2)
        .contentShape(shape)
        .keyframeAnimator(initialValue: Pose(), trigger: plays[.hop, default: 0], content: { Self.pose($0, $1) }) { _ in Self.hop }
        .keyframeAnimator(initialValue: Pose(), trigger: plays[.skip, default: 0], content: { Self.pose($0, $1) }) { _ in Self.skip }
        .keyframeAnimator(initialValue: Pose(), trigger: plays[.wiggle, default: 0], content: { Self.pose($0, $1) }) { _ in Self.wiggle }
        .keyframeAnimator(initialValue: Pose(), trigger: plays[.flip, default: 0], content: { Self.pose($0, $1) }) { _ in Self.flip }
        .onTapGesture {
            last = Reaction.allCases.filter { $0 != last }.randomElement()!
            plays[last, default: 0] += 1
        }
    }

    /// Static and nonisolated: the animator calls it from a @Sendable closure.
    nonisolated private static func pose(_ content: PlaceholderContentView<some View>, _ v: Pose) -> some View {
        content
            .scaleEffect(x: v.sx, y: v.sy, anchor: .bottom)
            .rotationEffect(.degrees(v.r))
            .offset(y: v.y)
    }

    // Heights are in points for the 46-point logo.

    @KeyframesBuilder<Pose> static var hop: some Keyframes<Pose> {
        KeyframeTrack(\Pose.sy) {
            SpringKeyframe(0.84, duration: 0.1)
            SpringKeyframe(1.08, duration: 0.16)
            SpringKeyframe(1, duration: 0.5, spring: .bouncy)
        }
        KeyframeTrack(\Pose.sx) {
            SpringKeyframe(1.12, duration: 0.1)
            SpringKeyframe(0.95, duration: 0.16)
            SpringKeyframe(1, duration: 0.5, spring: .bouncy)
        }
        KeyframeTrack(\Pose.y) {
            LinearKeyframe(0, duration: 0.1)
            SpringKeyframe(-12, duration: 0.18)
            SpringKeyframe(0, duration: 0.5, spring: .bouncy)
        }
        KeyframeTrack(\Pose.r) {
            LinearKeyframe(0, duration: 0.12)
            SpringKeyframe(-6, duration: 0.14)
            SpringKeyframe(4, duration: 0.18)
            SpringKeyframe(0, duration: 0.4, spring: .bouncy)
        }
    }

    @KeyframesBuilder<Pose> static var skip: some Keyframes<Pose> {
        KeyframeTrack(\Pose.sy) {
            SpringKeyframe(0.88, duration: 0.08)
            SpringKeyframe(1.05, duration: 0.12)
            SpringKeyframe(0.9, duration: 0.2)
            SpringKeyframe(1.03, duration: 0.1)
            SpringKeyframe(1, duration: 0.4, spring: .bouncy)
        }
        KeyframeTrack(\Pose.sx) {
            SpringKeyframe(1.08, duration: 0.08)
            SpringKeyframe(0.97, duration: 0.12)
            SpringKeyframe(1.06, duration: 0.2)
            SpringKeyframe(0.99, duration: 0.1)
            SpringKeyframe(1, duration: 0.4, spring: .bouncy)
        }
        KeyframeTrack(\Pose.y) {
            LinearKeyframe(0, duration: 0.08)
            SpringKeyframe(-9, duration: 0.14)
            SpringKeyframe(0, duration: 0.16)
            SpringKeyframe(-5, duration: 0.12)
            SpringKeyframe(0, duration: 0.4, spring: .bouncy)
        }
    }

    @KeyframesBuilder<Pose> static var wiggle: some Keyframes<Pose> {
        KeyframeTrack(\Pose.r) {
            SpringKeyframe(-11, duration: 0.09)
            SpringKeyframe(10, duration: 0.12)
            SpringKeyframe(-7, duration: 0.12)
            SpringKeyframe(4, duration: 0.12)
            SpringKeyframe(0, duration: 0.4, spring: .bouncy)
        }
        KeyframeTrack(\Pose.sy) {
            SpringKeyframe(0.94, duration: 0.09)
            SpringKeyframe(1, duration: 0.5, spring: .bouncy)
        }
    }

    @KeyframesBuilder<Pose> static var flip: some Keyframes<Pose> {
        KeyframeTrack(\Pose.sy) {
            SpringKeyframe(0.82, duration: 0.12)
            SpringKeyframe(1.04, duration: 0.14)
            CubicKeyframe(1, duration: 0.34)
            SpringKeyframe(0.9, duration: 0.08)
            SpringKeyframe(1, duration: 0.4, spring: .bouncy)
        }
        KeyframeTrack(\Pose.sx) {
            SpringKeyframe(1.14, duration: 0.12)
            SpringKeyframe(0.96, duration: 0.14)
            CubicKeyframe(1, duration: 0.34)
            SpringKeyframe(1.08, duration: 0.08)
            SpringKeyframe(1, duration: 0.4, spring: .bouncy)
        }
        KeyframeTrack(\Pose.y) {
            LinearKeyframe(0, duration: 0.12)
            CubicKeyframe(-20, duration: 0.24)
            CubicKeyframe(0, duration: 0.24)
            SpringKeyframe(0, duration: 0.48, spring: .bouncy)
        }
        KeyframeTrack(\Pose.r) {
            LinearKeyframe(0, duration: 0.14)
            CubicKeyframe(360, duration: 0.46)
            LinearKeyframe(360, duration: 0.48)
        }
    }
}

/// The icon's chestnut outline (App/AppIcon.icon/Assets/chestnut.svg), fitted to the rect.
struct ChestnutShape: Shape {
    static let svg = Path.svg(CHESTNUT_D)

    func path(in rect: CGRect) -> Path {
        let box = Self.svg.boundingRect
        let scale = min(rect.width / box.width, rect.height / box.height)
        let transform = CGAffineTransform(translationX: rect.midX, y: rect.midY)
            .scaledBy(x: scale, y: scale)
            .translatedBy(x: -box.midX, y: -box.midY)
        return Self.svg.applying(transform)
    }
}

extension Path {
    /// Absolute M, L, C and Z only: enough for the icon's path.
    static func svg(_ d: String) -> Path {
        var path = Path()
        let scanner = Scanner(string: d)
        scanner.charactersToBeSkipped = .whitespacesAndNewlines.union(CharacterSet(charactersIn: ","))
        func point() -> CGPoint { CGPoint(x: scanner.scanDouble() ?? 0, y: scanner.scanDouble() ?? 0) }
        var command: Character = "M"
        while !scanner.isAtEnd {
            if let c = scanner.scanCharacter(), c.isLetter { command = c } else {
                scanner.currentIndex = d.index(before: scanner.currentIndex)
            }
            switch command {
            case "M": path.move(to: point()); command = "L"
            case "L": path.addLine(to: point())
            case "C":
                let c1 = point(), c2 = point(), end = point()
                path.addCurve(to: end, control1: c1, control2: c2)
            case "Z", "z": path.closeSubpath()
            default: return path
            }
        }
        return path
    }
}

// MARK: - Conversation

struct Conversation: View {
    let space: Namespace.ID
    @Environment(Chat.self) private var chat
    @Environment(\.palette) private var palette
    /// The height left for content between the top margin and the composer.
    @State private var visible: CGFloat = 0

    var body: some View {
        // The latest exchange (the last user message and what follows) is at
        // least a screen tall, so a sent message can scroll to the top and the
        // reply grows below it.
        let split = chat.messages.lastIndex(where: \.fromUser) ?? 0
        let current = Array(chat.messages[split...])
        ScrollViewReader { proxy in
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                ForEach(chat.messages[..<split]) { message in
                    row(message)
                }
                VStack(alignment: .leading, spacing: 26) {
                    ForEach(current) { message in
                        row(message)
                    }
                    if case .working(let status) = chat.phase {
                        Working(status: status)
                            .padding(.horizontal, 6)
                            .transition(.opacity.combined(with: .offset(y: 6)))
                    }
                }
                .frame(minHeight: visible, alignment: .top)
                .id(current.first?.id)
            }
            .frame(maxWidth: 740)
            .padding(.horizontal, 48)
            .frame(maxWidth: .infinity)
        }
        .defaultScrollAnchor(.bottom)
        .safeAreaPadding(.top, 56)
        .scrollEdgeEffectStyle(.soft, for: .top)
        .onScrollGeometryChange(for: CGFloat.self) { geometry in
            // Already without the top margin and the composer.
            geometry.containerSize.height
        } action: { _, height in
            visible = max(0, height)
        }
        .onChange(of: chat.messages.last?.id) {
            guard let last = chat.messages.last, last.fromUser else { return }
            // Next pass, once the new exchange (and its height) is laid out.
            DispatchQueue.main.async {
                withAnimation(Tune.scroll) { proxy.scrollTo(last.id, anchor: .top) }
            }
        }
        .safeAreaInset(edge: .bottom) {
            Composer()
                .matchedGeometryEffect(id: "composer", in: space)
                .frame(maxWidth: 740)
                .padding(.horizontal, 48)
                .padding(.bottom, 18)
        }
        }
    }

    @ViewBuilder private func row(_ message: Chat.Message) -> some View {
        if message.fromUser {
            UserCard(text: message.text)
                .transition(.asymmetric(
                    insertion: .scale(scale: 0.98, anchor: .bottom).combined(with: .opacity).combined(with: .offset(y: 16)),
                    removal: .opacity))
        } else {
            // Inline Markdown only; full Markdown is the first item of the UI roadmap.
            Text(LocalizedStringKey(message.text))
                .font(Typeface.serif(16))
                .lineSpacing(5)
                .foregroundStyle(palette.ink)
                .textSelection(.enabled)
                .padding(.horizontal, 6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .transition(.opacity)
        }
    }
}

/// A user message: a pane of tinted glass on the surface. The glass gives
/// the edge light and the depth; no drawn shadows.
struct UserCard: View {
    let text: String
    @Environment(\.palette) private var palette

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
        Text(text)
            .font(Typeface.sans(15.5))
            .lineSpacing(3)
            .foregroundStyle(palette.ink)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            // The glass alone turns grey on a light surface: a warm fill inside
            // it sets the colour, the glass adds the edge light and depth.
            .background(shape.fill(palette.cardTop.opacity(palette.dark ? 0.45 : 0.75)))
            .glassEffect(.regular, in: shape)
    }
}

/// What the model is doing: three dots circling in depth, and the status
/// with light running across it.
struct Working: View {
    let status: String
    @Environment(\.palette) private var palette

    var body: some View {
        HStack(spacing: 12) {
            OrbitingDots()
            TimelineView(.animation) { context in
                let t = context.date.timeIntervalSinceReferenceDate
                let p = (t.truncatingRemainder(dividingBy: Tune.shimmer)) / Tune.shimmer * 1.8 - 0.4
                Text(status)
                    .font(Typeface.sans(15))
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

// MARK: - Composer

/// Frosted, a step darker than the background, floating just above it.
/// Controls blend into it; only send/stop stands out.
struct Composer: View {
    @Environment(Chat.self) private var chat
    @Environment(\.palette) private var palette
    @FocusState private var focused: Bool

    var body: some View {
        @Bindable var chat = chat
        let shape = RoundedRectangle(cornerRadius: 20, style: .continuous)
        VStack(alignment: .leading, spacing: 8) {
            TextField("Ask anything", text: $chat.draft, axis: .vertical)
                .textFieldStyle(.plain)
                .font(Typeface.sans(16))
                .foregroundStyle(palette.ink)
                .lineLimit(1...8)
                .focused($focused)
                .onSubmit { chat.send() }
                .padding(.horizontal, 5)
            HStack(spacing: 0) {
                QuietButton(glyph: .paperclip) {}
                QuietButton(glyph: .folder, label: "Kuri") {}
                Spacer()
                ModelPicker()
                SendButton()
                    .padding(.leading, 4)
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 13)
        .padding(.bottom, 9)
        .background {
            // Liquid Glass brightens what's under it (lighter than the surface in
            // dark mode); a tinted fill over a blur keeps it a step darker.
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
}

/// A shadow that only shows outside the shape, so glass above it stays clear.
struct OuterShadow<S: Shape>: View {
    let shape: S
    let color: Color
    let radius: CGFloat
    let y: CGFloat

    var body: some View {
        shape.fill(.black)
            .shadow(color: color, radius: radius, y: y)
            .mask {
                ZStack {
                    Rectangle().padding(-120)
                    shape.blendMode(.destinationOut)
                }
                .compositingGroup()
            }
            .allowsHitTesting(false)
    }
}

struct ModelPicker: View {
    @Environment(\.palette) private var palette
    @State private var model = "qwen3.5:2b"
    @State private var effort = "Low"

    var body: some View {
        Menu {
            Picker("Model", selection: $model) {
                ForEach(["qwen3.5:2b", "claude-opus-5-5", "apple/default"], id: \.self) { Text($0) }
            }
            Picker("Effort", selection: $effort) {
                ForEach(["Low", "Medium", "High"], id: \.self) { Text($0) }
            }
        } label: {
            HStack(spacing: 5) {
                Text(model).foregroundStyle(palette.ink.opacity(0.85))
                Text(effort).foregroundStyle(palette.faint)
                PencilIcon(glyph: .chevron, size: 12, color: palette.secondary)
            }
            .font(Typeface.sans(14))
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .modifier(HoverWash())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
    }
}

struct SendButton: View {
    @Environment(Chat.self) private var chat
    @Environment(\.palette) private var palette

    var body: some View {
        let ready = chat.busy || !chat.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        Button {
            chat.busy ? chat.stop() : chat.send()
        } label: {
            ZStack {
                Circle().fill(ready ? AnyShapeStyle(palette.accentFill) : AnyShapeStyle(palette.faint.opacity(0.45)))
                Circle().strokeBorder(LinearGradient(colors: [.white.opacity(0.35), .clear], startPoint: .top, endPoint: .center), lineWidth: 1)
                ZStack {
                    if chat.busy {
                        RoundedRectangle(cornerRadius: 2.5, style: .continuous)
                            .fill(.white)
                            .frame(width: 10, height: 10)
                            .transition(.scale(scale: 0.5).combined(with: .opacity))
                    } else {
                        PencilIcon(glyph: .arrowUp, size: 16, color: .white, weight: 1.7)
                            .transition(.scale(scale: 0.5).combined(with: .opacity))
                    }
                }
            }
            .frame(width: 30, height: 30)
            .compositingGroup()
            .shadow(color: palette.shadow.opacity(ready ? (palette.dark ? 0.4 : 0.12) : 0), radius: 2, y: 1)
            .animation(Tune.move, value: chat.busy)
            .animation(Tune.hover, value: ready)
        }
        .buttonStyle(Squish())
        .keyboardShortcut(chat.busy ? "." : .return, modifiers: chat.busy ? .command : [])
    }
}

// MARK: - Sidebar

/// The standard macOS sidebar, with the sketch's type. New chat sits above
/// the list, aligned with the section titles and a size up from the chats.
struct Sidebar: View {
    @Environment(\.palette) private var palette
    @State private var selection: String? = "Moving the sandbox module"

    var body: some View {
        List(selection: $selection) {
            Section("Today") {
                ForEach(["Moving the sandbox module", "Fallback models", "Flows with code references"], id: \.self) { title in
                    Text(title).font(Typeface.sans(13)).lineLimit(1).tag(title)
                }
            }
            Section("Earlier") {
                ForEach(["Anthropic adapter", "Parallel read-only tools", "Titles on the Apple model", "Queueing messages"], id: \.self) { title in
                    Text(title).font(Typeface.sans(13)).lineLimit(1).tag(title)
                }
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .top, spacing: 4) {
            Button {} label: {
                HStack(spacing: 8) {
                    PencilIcon(glyph: .compose, size: 17, color: palette.ink)
                    Text("New chat").font(Typeface.sans(14.5).weight(.medium)).foregroundStyle(palette.ink)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .modifier(HoverWash(shape: RoundedRectangle(cornerRadius: 8, style: .continuous)))
            }
            .buttonStyle(Squish())
            .padding(.horizontal, 10)
        }
    }
}

// MARK: - Controls

/// A soft wash behind a control while the pointer is over it.
struct HoverWash<S: Shape>: ViewModifier {
    var shape: S
    @Environment(\.palette) private var palette
    @State private var hovering = false

    init(shape: S = Capsule()) { self.shape = shape }

    func body(content: Content) -> some View {
        content
            .background(shape.fill(palette.wash).opacity(hovering ? 1 : 0))
            .contentShape(shape)
            .onHover { hovering = $0 }
            .animation(Tune.hover, value: hovering)
    }
}

/// Presses sink a little and spring back.
struct Squish: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.92 : 1)
            .animation(Tune.press, value: configuration.isPressed)
    }
}

/// A control that blends into the surface it sits on.
struct QuietButton: View {
    let glyph: Glyph
    var label: String? = nil
    let action: () -> Void
    @Environment(\.palette) private var palette

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                PencilIcon(glyph: glyph, size: 16, color: palette.secondary)
                if let label { Text(label).font(Typeface.sans(14)).foregroundStyle(palette.secondary) }
            }
            .padding(.horizontal, 7)
            .padding(.vertical, 5)
            .modifier(HoverWash())
        }
        .buttonStyle(Squish())
    }
}

// MARK: - Pencil icons

/// Icons drawn as if with a pencil: strokes through slightly wobbly points,
/// round caps, and a second faint pass for the graphite.
enum Glyph {
    case sidebar, paperclip, folder, arrowUp, stop, chevron, plus, compose

    /// Strokes on a 24-point grid.
    var strokes: [[CGPoint]] {
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x, y: y) }
        switch self {
        case .sidebar:
            return [[p(4, 5.5), p(20, 5.5), p(20, 18.5), p(4, 18.5), p(4, 5.4)], [p(9.5, 5.9), p(9.5, 18.2)]]
        case .paperclip:
            return [[p(17, 8.5), p(17, 16), p(15.5, 19.6), p(12, 21), p(8.5, 19.6), p(7, 16), p(7, 6.75), p(7.95, 4.45),
                     p(10.25, 3.5), p(12.55, 4.45), p(13.5, 6.75), p(13.5, 15.5), p(13.05, 16.6), p(12, 17),
                     p(10.95, 16.6), p(10.5, 15.5), p(10.5, 8.5)]]
        case .folder:
            return [[p(3.5, 18), p(3.5, 6), p(9.5, 6), p(11.5, 8.5), p(20.5, 8.5), p(20.5, 18), p(3.4, 18.1)]]
        case .arrowUp:
            return [[p(12, 19), p(12, 5.6)], [p(6.5, 11), p(12, 5.4), p(17.5, 11)]]
        case .stop:
            return [[p(6.5, 6.5), p(17.5, 6.5), p(17.5, 17.5), p(6.5, 17.5), p(6.5, 6.4)]]
        case .chevron:
            return [[p(7, 9.5), p(12, 14.5), p(17, 9.5)]]
        case .plus:
            return [[p(12, 5.5), p(12, 18.5)], [p(5.5, 12), p(18.5, 12)]]
        case .compose:
            // A sheet open at the top right, and a pencil writing into it.
            return [[p(12, 4.5), p(6.5, 4.5), p(4.5, 6.5), p(4.5, 17.5), p(6.5, 19.5), p(17.5, 19.5), p(19.5, 17.5), p(19.5, 12)],
                    [p(10, 14), p(10.6, 11.2), p(17.8, 4), p(20, 6.2), p(12.8, 13.4), p(10, 14)]]
        }
    }
}

struct PencilShape: Shape {
    let glyph: Glyph
    var seed: Double = 0
    var wobble: CGFloat = 0.42

    func path(in rect: CGRect) -> Path {
        let s = min(rect.width, rect.height) / 24
        let origin = CGPoint(x: rect.midX - 12 * s, y: rect.midY - 12 * s)
        var path = Path()
        for (k, stroke) in glyph.strokes.enumerated() {
            let points = densify(stroke, step: 2.4).enumerated().map { i, pt -> CGPoint in
                let end = i == 0 || i == densify(stroke, step: 2.4).count - 1
                let amount = wobble * (end ? 0.5 : 1)
                let jx = noise(Double(i) + Double(k) * 31 + seed) * amount
                let jy = noise(Double(i) * 1.7 + Double(k) * 17 + seed + 5) * amount
                return CGPoint(x: origin.x + (pt.x + jx) * s, y: origin.y + (pt.y + jy) * s)
            }
            guard points.count > 1 else { continue }
            path.move(to: points[0])
            if points.count > 2 {
                for i in 1..<(points.count - 1) {
                    let next = points[i + 1]
                    let mid = CGPoint(x: (points[i].x + next.x) / 2, y: (points[i].y + next.y) / 2)
                    path.addQuadCurve(to: mid, control: points[i])
                }
            }
            path.addLine(to: points[points.count - 1])
        }
        return path
    }

    /// Splits long segments, so straight lines wobble too, but keeps the corners.
    private func densify(_ points: [CGPoint], step: CGFloat) -> [CGPoint] {
        var out = [points[0]]
        for (a, b) in zip(points, points.dropFirst()) {
            let n = max(1, Int((hypot(b.x - a.x, b.y - a.y) / step).rounded()))
            for j in 1...n {
                let f = CGFloat(j) / CGFloat(n)
                out.append(CGPoint(x: a.x + (b.x - a.x) * f, y: a.y + (b.y - a.y) * f))
            }
        }
        return out
    }

    /// Deterministic noise in -1...1, so an icon looks the same every time.
    private func noise(_ x: Double) -> CGFloat {
        let v = sin(x * 12.9898 + 78.233) * 43758.5453
        return CGFloat((v - v.rounded(.down)) * 2 - 1)
    }
}

struct PencilIcon: View {
    let glyph: Glyph
    var size: CGFloat = 17
    var color: Color = .primary
    var weight: CGFloat = 1.5

    var body: some View {
        ZStack {
            PencilShape(glyph: glyph)
                .stroke(color.opacity(0.92), style: StrokeStyle(lineWidth: weight, lineCap: .round, lineJoin: .round))
            PencilShape(glyph: glyph, seed: 9, wobble: 0.6)
                .stroke(color.opacity(0.32), style: StrokeStyle(lineWidth: weight * 0.55, lineCap: .round, lineJoin: .round))
        }
        .frame(width: size, height: size)
    }
}

// MARK: - Data

let CHESTNUT_D = """
M143.4 29.7C142.5 29.4 140.5 31.4 139.1 32.3C137.7 33.1 136.3 34.1 134.8 34.8C133.3 35.6 131.8 36.3 130.2
36.9C128.7 37.5 127.1 38.1 125.5 38.6C123.9 39.2 122.3 39.6 120.7 40.1C119.1 40.5 117.5 40.9 115.9 41.3C114.2
41.6 112.6 41.9 110.9 42.2C109.3 42.5 107.6 42.8 106.0 43.0C104.3 43.2 102.6 43.3 101.0 43.5C99.3 43.6 97.6
43.7 96.0 43.7C94.3 43.8 92.6 43.8 91.0 43.9C89.3 43.9 87.6 43.9 85.9 44.0C84.3 44.1 82.6 44.1 80.9 44.3C79.3
44.5 77.6 44.7 76.0 44.9C74.3 45.2 72.7 45.5 71.0 45.9C69.4 46.3 67.8 46.8 66.2 47.3C64.6 47.8 63.1 48.4 61.5
49.1C60.0 49.7 58.5 50.4 57.0 51.2C55.5 52.0 54.1 52.9 52.7 53.8C51.3 54.7 50.0 55.7 48.7 56.8C47.4 57.8 46.1
59.0 45.0 60.2C43.8 61.3 42.7 62.6 41.6 63.9C40.6 65.2 39.7 66.6 38.8 68.0C37.9 69.4 37.1 70.9 36.4 72.4C35.6
73.9 35.0 75.5 34.4 77.0C33.9 78.6 33.4 80.2 33.0 81.8C32.6 83.5 32.2 85.1 32.0 86.8C31.7 88.4 31.6 90.1 31.4
91.7C31.3 93.4 31.3 95.1 31.4 96.8C31.4 98.4 31.5 100.1 31.7 101.8C31.9 103.4 32.1 105.1 32.4 106.7C32.7 108.4
33.1 110.0 33.5 111.6C33.9 113.2 34.4 114.8 35.0 116.4C35.5 118.0 36.2 119.5 36.8 121.1C37.5 122.6 38.3 124.1
39.1 125.6C39.8 127.0 40.7 128.5 41.6 129.9C42.5 131.3 43.4 132.7 44.4 134.0C45.4 135.4 46.4 136.7 47.5
138.0C48.6 139.3 49.7 140.5 50.8 141.7C52.0 142.9 53.2 144.1 54.4 145.2C55.7 146.4 56.9 147.5 58.2 148.5C59.5
149.6 60.8 150.6 62.2 151.6C63.5 152.6 64.9 153.5 66.3 154.4C67.7 155.3 69.2 156.1 70.7 156.9C72.1 157.8 73.6
158.5 75.1 159.2C76.6 160.0 78.1 160.6 79.7 161.3C81.2 161.9 82.8 162.5 84.4 163.0C86.0 163.6 87.6 164.1 89.2
164.6C90.8 165.0 92.4 165.4 94.0 165.8C95.7 166.2 97.3 166.5 98.9 166.8C100.6 167.1 102.2 167.3 103.9
167.5C105.6 167.7 107.2 167.8 108.9 167.9C110.6 167.9 112.2 167.9 113.9 167.9C115.6 167.8 117.3 167.8 118.9
167.7C120.6 167.5 122.2 167.3 123.9 167.0C125.5 166.7 127.2 166.3 128.8 165.9C130.4 165.5 132.0 165.0 133.6
164.4C135.2 163.9 136.7 163.2 138.2 162.5C139.7 161.8 141.2 161.0 142.7 160.2C144.1 159.4 145.5 158.5 146.9
157.5C148.3 156.6 149.6 155.6 150.9 154.5C152.2 153.4 153.4 152.3 154.6 151.1C155.8 149.9 156.9 148.7 158.0
147.4C159.0 146.1 160.0 144.8 161.0 143.4C161.9 142.0 162.7 140.5 163.5 139.0C164.2 137.6 164.9 136.0 165.5
134.5C166.1 132.9 166.6 131.3 167.0 129.7C167.4 128.1 167.7 126.4 168.0 124.8C168.2 123.1 168.4 121.4 168.5
119.8C168.6 118.1 168.6 116.4 168.5 114.8C168.4 113.1 168.2 111.4 168.0 109.8C167.8 108.1 167.5 106.5 167.1
104.8C166.7 103.2 166.3 101.6 165.8 100.0C165.3 98.4 164.7 96.8 164.1 95.3C163.5 93.7 162.8 92.2 162.0
90.7C161.3 89.2 160.5 87.7 159.8 86.2C159.0 84.7 158.2 83.3 157.4 81.8C156.6 80.3 155.8 78.9 155.0 77.4C154.3
75.9 153.6 74.4 152.8 72.9C152.1 71.4 151.5 69.8 150.8 68.3C150.2 66.7 149.6 65.2 149.0 63.6C148.4 62.1 147.8
60.5 147.3 58.9C146.8 57.3 146.3 55.7 145.9 54.1C145.5 52.5 145.1 50.8 144.8 49.2C144.5 47.5 144.2 45.9 144.0
44.2C143.9 42.6 143.8 40.9 143.8 39.2C143.8 37.6 144.1 35.8 144.0 34.2C144.0 32.6 144.2 30.0 143.4 29.7ZM39.5
107.7C40.4 106.9 42.9 107.6 44.5 107.7C46.2 107.9 47.9 108.2 49.5 108.5C51.2 108.8 52.8 109.3 54.4 109.7C56.0
110.2 57.6 110.8 59.2 111.4C60.8 112.0 62.3 112.6 63.9 113.3C65.4 113.9 66.9 114.7 68.4 115.4C70.0 116.1 71.5
116.8 73.0 117.6C74.5 118.3 76.0 119.1 77.5 119.8C79.0 120.6 80.5 121.4 82.0 122.2C83.4 123.0 84.9 123.8 86.4
124.7C87.8 125.5 89.3 126.3 90.8 127.2C92.2 128.1 93.6 128.9 95.1 129.8C96.5 130.7 97.9 131.7 99.3 132.6C100.7
133.5 102.1 134.4 103.5 135.3C104.9 136.3 106.3 137.2 107.7 138.2C109.1 139.2 110.4 140.1 111.8 141.2C113.1
142.2 114.4 143.2 115.7 144.4C117.0 145.5 118.2 146.6 119.4 147.8C120.6 149.0 121.8 150.2 122.9 151.4C123.9
152.7 125.1 154.0 125.9 155.5C126.8 156.9 128.3 158.9 127.8 160.0C127.4 161.0 124.9 161.3 123.3 161.8C121.8
162.2 120.0 162.4 118.3 162.6C116.7 162.8 115.0 162.9 113.3 162.9C111.6 163.0 110.0 163.0 108.3 162.9C106.6
162.8 104.9 162.7 103.2 162.5C101.6 162.3 99.9 162.1 98.2 161.8C96.6 161.5 95.0 161.1 93.3 160.6C91.7 160.2
90.1 159.7 88.5 159.2C86.9 158.6 85.3 158.1 83.8 157.4C82.2 156.8 80.7 156.1 79.1 155.4C77.6 154.6 76.1 153.9
74.7 153.0C73.2 152.2 71.8 151.3 70.3 150.4C68.9 149.5 67.5 148.6 66.2 147.6C64.8 146.6 63.5 145.6 62.2
144.5C60.8 143.5 59.6 142.4 58.3 141.3C57.1 140.1 55.9 138.9 54.7 137.7C53.6 136.5 52.4 135.3 51.3 134.0C50.2
132.7 49.2 131.4 48.2 130.0C47.2 128.6 46.3 127.2 45.4 125.8C44.5 124.4 43.7 122.9 42.9 121.4C42.2 119.9 41.5
118.4 40.9 116.8C40.2 115.2 39.4 113.6 39.2 112.0C38.9 110.5 38.6 108.4 39.5 107.7Z
"""
