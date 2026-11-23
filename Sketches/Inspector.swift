// Inspector: a sketch of the main window's right sidebar, following
// docs/ui.md (UI roadmap, item 6). A standalone app with fake data; it
// borrows the app's real styles (palette, type, pencil icons, buttons) by
// compiling App/Style/Style.swift alongside it.
//
//   swiftc -parse-as-library -default-isolation MainActor -O Sketches/Inspector.swift App/Style/Style.swift -o /tmp/inspector && /tmp/inspector
//
// Try: ⌘R runs the model's next step (a command streams into the sandbox
// preview, the plan moves, the context grows, git picks up the edit), ⇧⌘R
// starts over, ⌥⌘I shows or hides the inspector. Click a step to see its
// output; tick, double-click, add or remove tasks. The sliders menu (top
// right) switches the theme and the layout: stacked sections, or tabs.
// Environment overrides for screenshots: INSPECTOR_SCHEME=light|dark,
// INSPECTOR_LAYOUT=sections|tabs, INSPECTOR_TAB=steps|tasks|context|git|sandbox,
// INSPECTOR_RUN=<n> (runs n steps at launch), INSPECTOR_OFFSCREEN=1 (opens
// the window off-screen without activating, and prints its number for
// `screencapture -l`).

import AppKit
import SwiftUI

// MARK: - Tuning

/// The sketch's own timings, next to the app's `Tune`.
enum Pace {
    /// Between lines of a command's output.
    static let line = 0.07
    /// Before a command starts, as the model writes it.
    static let think = 0.6
    /// The cursor's blink, on and off.
    static let blink = 0.55
    /// A line arriving in the terminal.
    static let arrive = Animation.easeOut(duration: 0.16)
}

// MARK: - App

@main struct InspectorSketch: App {
    @NSApplicationDelegateAdaptor(Delegate.self) private var delegate

    init() {
        setvbuf(stdout, nil, _IOLBF, 0)
        let fonts = URL(filePath: #filePath).deletingLastPathComponent().appending(path: "../App/Fonts")
        for file in (try? FileManager.default.contentsOfDirectory(at: fonts, includingPropertiesForKeys: nil)) ?? []
        where ["ttf", "otf"].contains(file.pathExtension) {
            CTFontManagerRegisterFontsForURL(file as CFURL, .process, nil)
        }
    }

    var body: some Scene {
        WindowGroup("Kuri") {
            Root().frame(minWidth: 860, minHeight: 560)
        }
        .defaultSize(width: 1180, height: 780)
    }
}

final class Delegate: NSObject, NSApplicationDelegate {
    static var offscreen: Bool { ProcessInfo.processInfo.environment["INSPECTOR_OFFSCREEN"] == "1" }

    func applicationWillFinishLaunching(_ notification: Notification) {
        NSApplication.shared.setActivationPolicy(Self.offscreen ? .accessory : .regular)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        if !Self.offscreen { NSApplication.shared.activate() }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

/// Moves the window off-screen as soon as it exists, for screenshots that
/// don't cover (or take focus from) whatever is on screen.
struct Offscreen: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { Probe() }
    func updateNSView(_ nsView: NSView, context: Context) {}

    final class Probe: NSView {
        override func viewDidMoveToWindow() {
            guard let window, Delegate.offscreen else { return }
            let frame = NSRect(x: -6000, y: 200, width: 1180, height: 780)
            window.setFrame(frame, display: false)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                window.setFrame(frame, display: true)
                print("window \(window.windowNumber)")
            }
        }
    }
}

/// Only for the sketch.
enum Theme: String, CaseIterable {
    case system = "System", light = "Light", dark = "Dark"

    var appearance: NSAppearance? {
        switch self {
        case .system: nil
        case .light: NSAppearance(named: .aqua)
        case .dark: NSAppearance(named: .darkAqua)
        }
    }
}

/// The two arrangements to compare.
enum Layout: String, CaseIterable {
    case sections = "Stacked sections", tabs = "Tabs"
}

enum Pane5: String, CaseIterable, Identifiable {
    case steps = "Steps", tasks = "Tasks", context = "Context", git = "Git", sandbox = "Sandbox"
    var id: String { rawValue }

    var mark: Mark {
        switch self {
        case .steps: .terminal
        case .tasks: .checklist
        case .context: .gauge
        case .git: .branch
        case .sandbox: .box
        }
    }
}

struct Root: View {
    @Environment(\.colorScheme) private var scheme
    @State private var sim = Sim()
    @State private var columns: NavigationSplitViewVisibility = .detailOnly
    @State private var inspecting = true
    @State private var theme: Theme = .system
    @State private var layout: Layout = .sections
    @State private var tab: Pane5 = .steps

    var body: some View {
        let palette = Palette(scheme: scheme)
        NavigationSplitView(columnVisibility: $columns) {
            FakeSidebar()
                .navigationSplitViewColumnWidth(min: 240, ideal: 290, max: 380)
        } detail: {
            Chat()
                .ignoresSafeArea(edges: .top)
                .inspector(isPresented: $inspecting) {
                    Inspector(layout: layout, tab: $tab)
                        .inspectorColumnWidth(min: 270, ideal: 320, max: 460)
                }
                .toolbar {
                    ToolbarSpacer(.flexible)
                    ToolbarItem(placement: .primaryAction) {
                        Menu {
                            Picker("Theme", selection: $theme) {
                                ForEach(Theme.allCases, id: \.self) { Text($0.rawValue) }
                            }
                            Picker("Layout", selection: $layout) {
                                ForEach(Layout.allCases, id: \.self) { Text($0.rawValue) }
                            }
                            Divider()
                            Button("Run the Next Step") { Task { await sim.run(steps: 1) } }
                                .keyboardShortcut("r")
                            Button("Start Over") { withAnimation(Tune.move) { sim.reset() } }
                                .keyboardShortcut("r", modifiers: [.command, .shift])
                        } label: {
                            PencilIcon(glyph: .sliders, size: 16, color: palette.secondary)
                        }
                        .menuIndicator(.hidden)
                        .help("Sketch options")
                    }
                    ToolbarItem(placement: .primaryAction) {
                        Button { withAnimation(Tune.move) { inspecting.toggle() } } label: {
                            MarkIcon(mark: .inspector, size: 17, color: palette.secondary)
                        }
                        .keyboardShortcut("i", modifiers: [.command, .option])
                        .help(inspecting ? "Hide the inspector" : "Show the inspector")
                    }
                }
        }
        .toolbar(removing: .title)
        .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
        .background(Offscreen())
        .environment(\.palette, palette)
        .environment(sim)
        .onChange(of: theme) { _, theme in NSApp.appearance = theme.appearance }
        .onAppear {
            let env = ProcessInfo.processInfo.environment
            theme = Theme(rawValue: (env["INSPECTOR_SCHEME"] ?? "").capitalized) ?? .system
            NSApp.appearance = theme.appearance
            if env["INSPECTOR_LAYOUT"] == "tabs" { layout = .tabs }
            if let name = env["INSPECTOR_TAB"], let pane = Pane5.allCases.first(where: { $0.rawValue.lowercased() == name }) { tab = pane }
            if let runs = Int(env["INSPECTOR_RUN"] ?? "") {
                Task { await sim.run(steps: runs) }
            }
        }
    }
}

// MARK: - Fake data, and a model that moves

struct Turn: Identifiable {
    let id: Int
    let prompt: String
    let time: String
}

struct Step: Identifiable {
    enum Kind { case shell, plan, memory, search }

    let id = UUID()
    var turn: Int
    var kind: Kind
    var title: String
    var output: [String] = []
    var seconds: Double? = nil
    var exit: Int? = nil
    var running = false
    /// What its result costs in the context.
    var tokens = 0
}

struct TaskItem: Identifiable, Equatable {
    enum Status { case pending, active, done }

    let id = UUID()
    var text: String
    var status: Status
}

struct ContextPart: Identifiable {
    let id: String
    var tokens: Int
}

struct GitFile: Identifiable {
    var id: String { path }
    let path: String
    let change: Character
    var added: Int
    var removed: Int
}

struct TermLine: Identifiable {
    enum Kind { case prompt, output, fail, pass }

    let id = UUID()
    let text: String
    let kind: Kind

    init(_ text: String) {
        self.text = text
        kind = text.hasPrefix("$ ") ? .prompt : text.hasPrefix("✘") ? .fail : text.hasPrefix("✔") ? .pass : .output
    }
}

/// One step the model takes when ⌘R is pressed.
struct ScriptStep {
    let kind: Step.Kind
    let title: String
    var output: [String] = []
    var exit = 0
    var seconds = 0.4
    var tokens = 300
    var effect: (Sim) -> Void = { _ in }
}

@Observable final class Sim {
    var turns: [Turn] = []
    var steps: [Step] = []
    var tasks: [TaskItem] = []
    var context: [ContextPart] = []
    let window = 128_000
    var branch = "fix/iso-weeks"
    var ahead = 1
    var files: [GitFile] = []
    var terminal: [TermLine] = []
    var running = false
    /// A turn is under way (one or more steps in a row).
    var working = false
    /// The command the sandbox is running, if any.
    var current: String?
    /// The user changed the plan since the model last wrote it.
    var userEdited = false
    var replies: [String] = []
    private var next = 0
    private var generation = 0

    var used: Int { context.reduce(0) { $0 + $1.tokens } }

    init() { reset() }

    func reset() {
        generation += 1
        next = 0
        running = false
        working = false
        current = nil
        userEdited = false
        turns = [Turn(id: 1, prompt: "The date parser test fails on ISO week dates like 2026-W48-1. Can you fix it?", time: "14:02")]
        steps = [
            Step(turn: 1, kind: .shell, title: "git status --short", output: [" M Tests/NotesTests/DateParserTests.swift"], seconds: 0.1, exit: 0, tokens: 40),
            Step(turn: 1, kind: .shell, title: "swift test --filter DateParserTests", output: Script.failingTest, seconds: 4.2, exit: 1, tokens: 1_850),
            Step(turn: 1, kind: .plan, title: "Made a plan · 1/4", seconds: nil, tokens: 120),
            Step(turn: 1, kind: .shell, title: "sed -n '40,96p' Sources/Notes/DateParser.swift", output: Script.source, seconds: 0.0, exit: 0, tokens: 2_400),
            Step(turn: 1, kind: .shell, title: "rg -n 'weekOfYear|yearForWeekOfYear' Sources", output: ["Sources/Notes/DateParser.swift:71:        components.weekOfYear = week"], seconds: 0.1, exit: 0, tokens: 60),
        ]
        tasks = [
            TaskItem(text: "Reproduce the failing test", status: .done),
            TaskItem(text: "Parse ISO week dates (2026-W48-1)", status: .active),
            TaskItem(text: "Run the whole test suite", status: .pending),
            TaskItem(text: "Note the format in the README", status: .pending),
        ]
        context = [
            ContextPart(id: "System", tokens: 6_100),
            ContextPart(id: "Memory", tokens: 640),
            ContextPart(id: "Messages", tokens: 2_900),
            ContextPart(id: "Tool output", tokens: 4_470),
        ]
        files = [GitFile(path: "Tests/NotesTests/DateParserTests.swift", change: "M", added: 9, removed: 0)]
        ahead = 1
        terminal = Script.failingTest.suffix(4).map(TermLine.init)
        replies = ["The test fails before parsing gets anywhere: `weekOfYear` is set, but the year it belongs to isn't, so `Calendar` can't place the week."]
    }

    /// A turn of a few steps, the sandbox preview open throughout.
    func run(steps count: Int) async {
        guard !working else { return }
        withAnimation(Tune.move) { working = true }
        for _ in 0..<count { await runNext() }
        try? await Task.sleep(for: .seconds(0.8))
        withAnimation(Tune.move) { working = false }
    }

    func runNext() async {
        guard !running, next < Script.steps.count else { return }
        let script = Script.steps[next]
        let generation = generation
        next += 1
        running = true
        try? await Task.sleep(for: .seconds(Pace.think))
        guard generation == self.generation else { return }

        var step = Step(turn: 1, kind: script.kind, title: script.title, running: true)
        withAnimation(Tune.move) { steps.append(step) }
        if script.kind == .shell {
            current = script.title
            withAnimation(Pace.arrive) { terminal.append(TermLine("$ " + script.title)) }
            for line in script.output {
                try? await Task.sleep(for: .seconds(Pace.line))
                guard generation == self.generation else { return }
                withAnimation(Pace.arrive) {
                    terminal.append(TermLine(line))
                    if terminal.count > 60 { terminal.removeFirst(terminal.count - 60) }
                }
            }
        } else {
            try? await Task.sleep(for: .seconds(0.3))
        }
        guard generation == self.generation else { return }
        step.running = false
        step.output = script.output
        step.exit = script.kind == .shell ? script.exit : nil
        step.seconds = script.kind == .shell ? script.seconds : nil
        step.tokens = script.tokens
        withAnimation(Tune.move) {
            if let index = steps.firstIndex(where: { $0.id == step.id }) { steps[index] = step }
            if let index = context.firstIndex(where: { $0.id == "Tool output" }) { context[index].tokens += script.tokens }
            if let index = context.firstIndex(where: { $0.id == "Messages" }) { context[index].tokens += 180 }
            script.effect(self)
            current = nil
            running = false
        }
    }

    func setStatus(_ status: TaskItem.Status, at index: Int) {
        guard tasks.indices.contains(index) else { return }
        tasks[index].status = status
        if status == .active {
            for other in tasks.indices where other != index && tasks[other].status == .active { tasks[other].status = .pending }
        }
    }
}

enum Script {
    static let failingTest = [
        "Building for debugging...",
        "[14/14] Linking NotesPackageTests",
        "Build complete! (3.61s)",
        "◇ Suite DateParserTests started.",
        "✘ Test parsesISOWeekDates() recorded an issue at DateParserTests.swift:52:9",
        "  Expectation failed: (parsed → nil) == (expected → 2026-11-23)",
        "✘ Suite DateParserTests failed after 0.031 seconds with 1 issue.",
        "✘ Test run with 6 tests in 1 suite failed after 0.031 seconds with 1 issue.",
    ]

    static let source = [
        "    func parse(_ text: String) -> Date? {",
        "        if let match = text.wholeMatch(of: isoWeek) {",
        "            var components = DateComponents()",
        "            components.weekOfYear = Int(match.week)",
        "            components.weekday = Int(match.day).map { $0 % 7 + 1 }",
        "            return calendar.date(from: components)",
        "        }",
        "        …",
    ]

    static let steps: [ScriptStep] = [
        ScriptStep(kind: .shell, title: "python3 - <<'EOF'  # set yearForWeekOfYear", output: ["patched Sources/Notes/DateParser.swift (1 hunk)"], seconds: 0.1, tokens: 90) { sim in
            sim.files.insert(GitFile(path: "Sources/Notes/DateParser.swift", change: "M", added: 14, removed: 3), at: 0)
            sim.replies.append("Setting `yearForWeekOfYear` alongside the week fixes it, and the calendar has to be ISO 8601 for weeks to start on Monday.")
        },
        ScriptStep(kind: .shell, title: "swift test --filter DateParserTests", output: [
            "Building for debugging...",
            "[9/9] Linking NotesPackageTests",
            "Build complete! (2.84s)",
            "◇ Suite DateParserTests started.",
            "✔ Suite DateParserTests passed after 0.024 seconds.",
            "✔ Test run with 6 tests in 1 suite passed after 0.024 seconds.",
        ], seconds: 3.1, tokens: 420) { sim in
            sim.setStatus(.done, at: 1)
            sim.setStatus(.active, at: 2)
        },
        ScriptStep(kind: .shell, title: "swift test", output: [
            "Building for debugging...",
            "Build complete! (0.42s)",
            "◇ Suite NoteStoreTests started.",
            "◇ Suite DateParserTests started.",
            "◇ Suite ExportTests started.",
            "✔ Suite DateParserTests passed after 0.022 seconds.",
            "✔ Suite ExportTests passed after 0.310 seconds.",
            "✔ Suite NoteStoreTests passed after 1.204 seconds.",
            "✔ Test run with 41 tests in 3 suites passed after 1.207 seconds.",
        ], seconds: 11.8, tokens: 960) { sim in
            sim.setStatus(.done, at: 2)
            sim.setStatus(.active, at: 3)
        },
        ScriptStep(kind: .shell, title: "perl -0pi -e 's/(## Dates\\n)/$1\\nISO weeks too: 2026-W48-1.\\n/' README.md", output: [], seconds: 0.0, tokens: 20) { sim in
            sim.files.append(GitFile(path: "README.md", change: "M", added: 2, removed: 0))
            sim.setStatus(.done, at: 3)
        },
        ScriptStep(kind: .memory, title: "Saved a memory", tokens: 60) { sim in
            sim.replies.append("All 41 tests pass. The parser now handles ISO week dates, and the README mentions the format. Nothing is committed yet.")
        },
    ]
}

// MARK: - Inspector

struct Inspector: View {
    let layout: Layout
    @Binding var tab: Pane5
    @Environment(Sim.self) private var sim
    @Environment(\.palette) private var palette

    var body: some View {
        switch layout {
        case .sections:
            ScrollView {
                VStack(spacing: 8) {
                    ForEach(Pane5.allCases.filter { $0 != .sandbox }) { pane in
                        InspectorSection(pane: pane) { PaneBody(pane: pane, compact: true) }
                    }
                }
                .padding(.horizontal, 10)
                .padding(.top, 4)
                .padding(.bottom, 16)
            }
            .scrollEdgeEffectStyle(.soft, for: .top)
            // The sandbox stays in view at the bottom, as the composer does
            // in the chat: it's what moves while the model works.
            .safeAreaInset(edge: .bottom, spacing: 0) {
                InspectorSection(pane: .sandbox) { PaneBody(pane: .sandbox, compact: true) }
                    .padding(.horizontal, 10)
                    .padding(.top, 14)
                    .padding(.bottom, 10)
                    .background {
                        LinearGradient(stops: [.init(color: surface.opacity(0), location: 0), .init(color: surface, location: 0.3)],
                                       startPoint: .top, endPoint: .bottom)
                    }
            }
            .background(surface.ignoresSafeArea())
        case .tabs:
            VStack(spacing: 0) {
                TabStrip(selection: $tab)
                    .padding(.horizontal, 10)
                    .padding(.bottom, 8)
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(alignment: .firstTextBaseline) {
                            Text(tab.rawValue).font(Typeface.serif(17))
                            Spacer()
                            Accessory(pane: tab)
                        }
                        PaneBody(pane: tab, compact: false)
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 6)
                    .padding(.bottom, 16)
                    .id(tab)
                    .transition(.opacity.combined(with: .offset(y: 6)))
                }
                .scrollEdgeEffectStyle(.soft, for: .top)
            }
            .animation(Tune.move, value: tab)
            .background(surface.ignoresSafeArea())
        }
    }

    /// Warm like the chat, a step off it: the native inspector is a cool grey.
    private var surface: Color { palette.dark ? rgb(0x211F1D) : rgb(0xF3F1EA) }
}

/// A box per section, its header folding it.
struct InspectorSection<Content: View>: View {
    let pane: Pane5
    @ViewBuilder var content: Content
    @Environment(\.palette) private var palette
    @State private var open = true

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 7) {
                MarkIcon(mark: pane.mark, size: 14, color: palette.secondary)
                Text(pane.rawValue).font(Typeface.serif(14)).foregroundStyle(palette.ink)
                Spacer(minLength: 6)
                Accessory(pane: pane)
                PencilIcon(glyph: .chevron, size: 10, color: palette.faint)
                    .rotationEffect(.degrees(open ? 0 : -90))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .contentShape(.rect)
            .onTapGesture { withAnimation(Tune.move) { open.toggle() } }
            if open {
                content
                    .padding(.horizontal, 10)
                    .padding(.bottom, 10)
                    .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .clipped()
        .modifier(Box())
    }
}

/// A box resting on the inspector: a warm fill, a hairline, a soft contact
/// shadow.
struct Box: ViewModifier {
    @Environment(\.palette) private var palette

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
        content
            // Solid, so the pinned sandbox hides what scrolls under it.
            .background(shape.fill(palette.dark ? rgb(0x292724) : rgb(0xFFFDF8)))
            .overlay(shape.strokeBorder(palette.ink.opacity(palette.dark ? 0.07 : 0.06), lineWidth: 1))
            .shadow(color: palette.shadow.opacity(palette.dark ? 0.25 : 0.05), radius: 1.5, y: 1)
    }
}

/// What each header says on the right, so a folded section still tells
/// something.
struct Accessory: View {
    let pane: Pane5
    @Environment(Sim.self) private var sim
    @Environment(\.palette) private var palette

    var body: some View {
        Group {
            switch pane {
            case .steps:
                Text("\(sim.steps.filter { $0.kind == .shell }.count) commands")
            case .tasks:
                Text("\(sim.tasks.filter { $0.status == .done }.count)/\(sim.tasks.count)")
            case .context:
                Text("\(Int((Double(sim.used) / Double(sim.window) * 100).rounded()))%")
            case .git:
                Text(sim.files.count == 1 ? "1 change" : "\(sim.files.count) changes")
            case .sandbox:
                if sim.current != nil {
                    HStack(spacing: 4) { Orb(size: 6); Text("Running") }
                } else {
                    Text("Idle")
                }
            }
        }
        .font(Typeface.sans(11.5).monospacedDigit())
        .foregroundStyle(palette.faint)
        .contentTransition(.numericText())
        .animation(Tune.status, value: sim.used)
    }
}

/// Tabs: one pencil icon each, the chosen one washed.
struct TabStrip: View {
    @Binding var selection: Pane5
    @Environment(\.palette) private var palette
    @Namespace private var space

    var body: some View {
        HStack(spacing: 2) {
            ForEach(Pane5.allCases) { pane in
                Button { selection = pane } label: {
                    MarkIcon(mark: pane.mark, size: 16, color: selection == pane ? palette.accent : palette.secondary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                        .background {
                            if selection == pane {
                                RoundedRectangle(cornerRadius: 7, style: .continuous)
                                    .fill(palette.wash)
                                    .matchedGeometryEffect(id: "tab", in: space)
                            }
                        }
                        .modifier(HoverWash())
                }
                .buttonStyle(Squish())
                .help(pane.rawValue)
            }
        }
        .padding(3)
        .modifier(Box())
    }
}

struct PaneBody: View {
    let pane: Pane5
    /// Stacked, sections show less (the latest steps, a shorter terminal).
    let compact: Bool

    var body: some View {
        switch pane {
        case .steps: StepsPane(limit: compact ? 6 : nil)
        case .tasks: TasksPane()
        case .context: ContextPane(compact: compact)
        case .git: GitPane()
        case .sandbox: SandboxPane(height: compact ? 140 : 320, alwaysOpen: !compact)
        }
    }
}

// MARK: - Steps

/// Every tool call, turn by turn; commands up front, the rest quieter.
struct StepsPane: View {
    let limit: Int?
    @Environment(Sim.self) private var sim
    @Environment(\.palette) private var palette
    @State private var commandsOnly = false
    @State private var showAll = false

    var body: some View {
        let visible = sim.steps.filter { !commandsOnly || $0.kind == .shell }
        let shown = limit.map { showAll ? visible : Array(visible.suffix($0)) } ?? visible
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 2) {
                Pill(title: "All", on: !commandsOnly) { commandsOnly = false }
                Pill(title: "Commands", on: commandsOnly) { commandsOnly = true }
                Spacer()
                if shown.count < visible.count {
                    Button("Show all \(visible.count)") { withAnimation(Tune.move) { showAll = true } }
                        .buttonStyle(.plain)
                        .font(Typeface.sans(11.5))
                        .foregroundStyle(palette.secondary)
                }
            }
            .padding(.bottom, 4)
            ForEach(sim.turns) { turn in
                let rows = shown.filter { $0.turn == turn.id }
                if !rows.isEmpty {
                    HStack(spacing: 6) {
                        Text("“\(turn.prompt)”").lineLimit(1).truncationMode(.tail)
                        Spacer(minLength: 4)
                        Text(turn.time).monospacedDigit()
                    }
                    .font(Typeface.sans(11))
                    .foregroundStyle(palette.faint)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    ForEach(rows) { step in
                        StepRow(step: step)
                            .transition(.opacity.combined(with: .offset(y: 6)))
                    }
                }
            }
        }
    }
}

struct Pill: View {
    let title: String
    let on: Bool
    let action: () -> Void
    @Environment(\.palette) private var palette

    var body: some View {
        Button(action: { withAnimation(Tune.move) { action() } }) {
            Text(title)
                .font(Typeface.sans(11.5))
                .foregroundStyle(on ? palette.ink : palette.faint)
                .padding(.horizontal, 7)
                .padding(.vertical, 2.5)
                .background(Capsule().fill(palette.wash).opacity(on ? 1 : 0))
                .modifier(HoverWash(shape: Capsule()))
        }
        .buttonStyle(Squish())
    }
}

struct StepRow: View {
    let step: Step
    @Environment(\.palette) private var palette
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 7) {
                StepStatus(step: step).frame(width: 16)
                if step.kind == .shell {
                    Text(step.title)
                        .font(Typeface.mono(11.5))
                        .foregroundStyle(palette.ink)
                        .lineLimit(1)
                        .truncationMode(.tail)
                } else {
                    Text(step.title)
                        .font(Typeface.sans(12))
                        .foregroundStyle(palette.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 4)
                if let seconds = step.seconds {
                    Text(seconds < 0.05 ? "<0.1s" : String(format: "%.1fs", seconds))
                        .font(Typeface.sans(10.5).monospacedDigit())
                        .foregroundStyle(palette.faint)
                }
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
            .modifier(HoverWash(shape: RoundedRectangle(cornerRadius: 6, style: .continuous)))
            .onTapGesture { if !step.output.isEmpty { withAnimation(Tune.move) { expanded.toggle() } } }
            .help(step.output.isEmpty ? step.title : "Click to see the output")
            if expanded {
                TerminalText(lines: step.output.map(TermLine.init), cursor: false)
                    .frame(maxHeight: 160)
                    .padding(.leading, 26)
                    .padding(.trailing, 2)
                    .padding(.bottom, 4)
                    .transition(.opacity.combined(with: .offset(y: -4)))
            }
        }
    }
}

/// Running, passed, failed (with its exit code), or the tool's own mark.
struct StepStatus: View {
    let step: Step
    @Environment(\.palette) private var palette

    var body: some View {
        if step.running {
            Orb(size: 6)
        } else if step.kind != .shell {
            MarkIcon(mark: step.kind == .plan ? .checklist : step.kind == .memory ? .bookmark : .search, size: 12, color: palette.faint)
        } else if let exit = step.exit, exit != 0 {
            Text("\(exit)")
                .font(Typeface.mono(9.5).weight(.bold))
                .foregroundStyle(.white)
                .frame(minWidth: 14, minHeight: 14)
                .background(Circle().fill(palette.accentFill))
                .help("Exit status \(exit)")
        } else {
            PencilIcon(glyph: .check, size: 12, color: palette.faint)
        }
    }
}

// MARK: - Tasks

/// The model's plan, which the user can change: tick, rename, add, remove.
struct TasksPane: View {
    @Environment(Sim.self) private var sim
    @Environment(\.palette) private var palette
    @State private var adding = false
    @State private var draft = ""
    @FocusState private var addFocused: Bool

    var body: some View {
        @Bindable var sim = sim
        VStack(alignment: .leading, spacing: 1) {
            ForEach($sim.tasks) { $task in
                TaskRow(task: $task) {
                    withAnimation(Tune.move) {
                        sim.tasks.removeAll { $0.id == task.id }
                        sim.userEdited = true
                    }
                } edited: {
                    sim.userEdited = true
                }
                .transition(.opacity.combined(with: .offset(y: -4)))
            }
            if adding {
                HStack(spacing: 8) {
                    Check(status: .pending)
                    TextField("", text: $draft, prompt: Text(""))
                        .textFieldStyle(.plain)
                        .font(Typeface.sans(12.5))
                        .labelsHidden()
                        .focused($addFocused)
                        .onSubmit(add)
                        .onExitCommand { adding = false; draft = "" }
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 4)
            }
            HStack {
                Button {
                    withAnimation(Tune.move) { adding = true }
                    addFocused = true
                } label: {
                    HStack(spacing: 5) {
                        PencilIcon(glyph: .plus, size: 11, color: palette.secondary)
                        Text("Add task")
                    }
                    .font(Typeface.sans(11.5))
                    .foregroundStyle(palette.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .modifier(HoverWash())
                }
                .buttonStyle(Squish())
                Spacer()
                if sim.userEdited {
                    Text("Kuri sees your changes at its next step")
                        .font(Typeface.sans(10.5))
                        .foregroundStyle(palette.faint)
                        .multilineTextAlignment(.trailing)
                        .transition(.opacity)
                }
            }
            .padding(.top, 4)
        }
    }

    private func add() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        draft = ""
        guard !text.isEmpty else { adding = false; return }
        withAnimation(Tune.move) {
            sim.tasks.append(TaskItem(text: text, status: .pending))
            sim.userEdited = true
        }
        addFocused = true
    }
}

struct TaskRow: View {
    @Binding var task: TaskItem
    let remove: () -> Void
    let edited: () -> Void
    @Environment(\.palette) private var palette
    @State private var editing = false
    @State private var hovering = false
    @State private var draft = ""
    @FocusState private var focused: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Button {
                withAnimation(Tune.press) { task.status = task.status == .done ? .pending : .done }
                edited()
            } label: { Check(status: task.status) }
                .buttonStyle(Squish())
                .padding(.top, 1)
            if editing {
                TextField("", text: $draft, prompt: Text(""), axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(Typeface.sans(12.5))
                    .labelsHidden()
                    .focused($focused)
                    .onSubmit(commit)
                    .onExitCommand { editing = false }
                    .onChange(of: focused) { _, now in if !now { commit() } }
            } else {
                Text(task.text)
                    .font(Typeface.sans(12.5))
                    .foregroundStyle(task.status == .done ? palette.faint : palette.ink)
                    .strikethrough(task.status == .done, color: palette.faint)
                    .fontWeight(task.status == .active ? .medium : .regular)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(.rect)
                    .onTapGesture(count: 2) {
                        draft = task.text
                        editing = true
                        focused = true
                    }
                    .help("Double-click to edit")
            }
            Button(action: remove) {
                PencilIcon(glyph: .xmark, size: 10, color: palette.faint).padding(2)
            }
            .buttonStyle(Squish())
            .opacity(hovering && !editing ? 1 : 0)
            .help("Remove")
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(palette.wash).opacity(hovering ? 1 : 0))
        .onHover { hovering = $0 }
        .animation(Tune.hover, value: hovering)
    }

    private func commit() {
        guard editing else { return }
        editing = false
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty, text != task.text {
            task.text = text
            edited()
        }
    }
}

/// Empty, in progress (a dot in the accent), or done (filled and ticked).
struct Check: View {
    let status: TaskItem.Status
    @Environment(\.palette) private var palette

    var body: some View {
        ZStack {
            switch status {
            case .pending:
                Circle().strokeBorder(palette.faint.opacity(0.9), lineWidth: 1.2)
            case .active:
                Circle().strokeBorder(palette.accent, lineWidth: 1.3)
                Circle().fill(palette.accentFill).padding(3.5)
            case .done:
                Circle().fill(palette.accentFill)
                PencilIcon(glyph: .check, size: 10, color: .white, weight: 1.7)
            }
        }
        .frame(width: 14, height: 14)
        .contentShape(Circle())
    }
}

// MARK: - Context

/// What fills the window: one bar, its parts, and the biggest results.
struct ContextPane: View {
    let compact: Bool
    @Environment(Sim.self) private var sim
    @Environment(\.palette) private var palette

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                Text(short(sim.used))
                    .font(Typeface.serif(20))
                    .foregroundStyle(palette.ink)
                    .contentTransition(.numericText())
                Text("of \(short(sim.window)) tokens")
                    .font(Typeface.sans(12))
                    .foregroundStyle(palette.faint)
                Spacer()
            }
            .animation(Tune.status, value: sim.used)
            ContextBar()
            Grid(horizontalSpacing: 14, verticalSpacing: 3) {
                ForEach(0..<(sim.context.count + 1) / 2, id: \.self) { row in
                    GridRow {
                        ForEach(sim.context.dropFirst(row * 2).prefix(2)) { part in
                            HStack(spacing: 6) {
                                Circle().fill(tone(part.id)).frame(width: 7, height: 7)
                                Text(part.id).foregroundStyle(palette.secondary).lineLimit(1)
                                Spacer(minLength: 4)
                                Text(short(part.tokens))
                                    .foregroundStyle(palette.faint)
                                    .monospacedDigit()
                                    .contentTransition(.numericText())
                            }
                            .font(Typeface.sans(11.5))
                        }
                    }
                }
            }
            .animation(Tune.status, value: sim.used)
            if !compact { VStack(alignment: .leading, spacing: 3) {
                Text("Largest results").font(Typeface.sans(11)).foregroundStyle(palette.faint)
                ForEach(sim.steps.sorted { $0.tokens > $1.tokens }.prefix(3)) { step in
                    HStack(spacing: 7) {
                        Text(step.title).font(step.kind == .shell ? Typeface.mono(11) : Typeface.sans(11.5)).foregroundStyle(palette.secondary).lineLimit(1)
                        Spacer(minLength: 6)
                        Text(short(step.tokens)).font(Typeface.sans(11.5).monospacedDigit()).foregroundStyle(palette.faint)
                    }
                }
            } }
            HStack {
                Text("Compacts at 75%")
                    .font(Typeface.sans(10.5))
                    .foregroundStyle(palette.faint)
                Spacer()
                Button {} label: {
                    Text("Compact now").font(Typeface.sans(11.5)).padding(.horizontal, 9).padding(.vertical, 3.5)
                }
                .buttonStyle(SecondaryButton())
            }
        }
    }

    private func tone(_ part: String) -> Color { ContextBar.tone(part, palette) }
}

struct ContextBar: View {
    @Environment(Sim.self) private var sim
    @Environment(\.palette) private var palette
    /// Where compaction starts.
    static let threshold = 0.75

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            ZStack(alignment: .leading) {
                Capsule().fill(palette.wash)
                HStack(spacing: 1.5) {
                    ForEach(sim.context) { part in
                        Rectangle()
                            .fill(Self.tone(part.id, palette))
                            .frame(width: max(2, width * CGFloat(part.tokens) / CGFloat(sim.window)))
                    }
                }
                .clipShape(Capsule())
                Rectangle()
                    .fill(palette.faint)
                    .frame(width: 1.5, height: 12)
                    .offset(x: width * Self.threshold)
                    .help("Kuri summarizes earlier messages here")
            }
        }
        .frame(height: 8)
        .animation(Tune.move, value: sim.used)
    }

    static func tone(_ part: String, _ palette: Palette) -> Color {
        switch part {
        case "System": palette.faint.opacity(0.8)
        case "Memory": Term(dark: palette.dark).yellow
        case "Messages": palette.accentLight
        default: palette.accent
        }
    }
}

func short(_ tokens: Int) -> String {
    tokens < 1_000 ? "\(tokens)" : String(format: "%.1fk", Double(tokens) / 1_000)
}

// MARK: - Git

/// Read-only: Kuri isn't a git client, this is so you know where things stand.
struct GitPane: View {
    @Environment(Sim.self) private var sim
    @Environment(\.palette) private var palette

    var body: some View {
        let term = Term(dark: palette.dark)
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                PencilIcon(glyph: .folder, size: 12, color: palette.faint)
                Text("kuri-notes").font(Typeface.sans(12)).foregroundStyle(palette.secondary)
                Spacer()
                MarkIcon(mark: .branch, size: 12, color: palette.faint)
                Text(sim.branch).font(Typeface.mono(11)).foregroundStyle(palette.ink)
                if sim.ahead > 0 {
                    Text("↑\(sim.ahead)").font(Typeface.sans(11).monospacedDigit()).foregroundStyle(palette.faint)
                        .help("\(sim.ahead) commit ahead of origin/main")
                }
            }
            VStack(spacing: 1) {
                ForEach(sim.files) { file in
                    HStack(spacing: 7) {
                        Text(String(file.change))
                            .font(Typeface.mono(10.5).weight(.bold))
                            .foregroundStyle(file.change == "A" ? term.green : file.change == "D" ? term.red : term.yellow)
                            .frame(width: 10)
                        let parts = file.path.split(separator: "/")
                        Text("\(Text(parts.dropLast().joined(separator: "/") + (parts.count > 1 ? "/" : "")).foregroundStyle(palette.faint))\(Text(String(parts.last ?? "")).foregroundStyle(palette.ink))")
                            .font(Typeface.sans(12))
                            .lineLimit(1)
                            .truncationMode(.head)
                        Spacer(minLength: 4)
                        HStack(spacing: 4) {
                            if file.added > 0 { Text("+\(file.added)").foregroundStyle(term.green) }
                            if file.removed > 0 { Text("−\(file.removed)").foregroundStyle(term.red) }
                        }
                        .font(Typeface.mono(10.5))
                    }
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3.5)
                    .modifier(HoverWash(shape: RoundedRectangle(cornerRadius: 6, style: .continuous)))
                    .help(file.path)
                    .transition(.opacity.combined(with: .offset(y: -4)))
                }
            }
            Text("a41c9e2  Add a test for ISO week dates · 2 h ago")
                .font(Typeface.sans(11))
                .foregroundStyle(palette.faint)
                .lineLimit(1)
                .padding(.horizontal, 6)
        }
    }
}

// MARK: - Sandbox

/// The VM at a glance, and a live tail of what runs in it.
struct SandboxPane: View {
    let height: CGFloat
    /// Stacked, the terminal shows only while the model works.
    let alwaysOpen: Bool
    @Environment(Sim.self) private var sim
    @Environment(\.palette) private var palette

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                ZStack {
                    Circle().fill(palette.faint.opacity(0.6)).frame(width: 5, height: 5).opacity(sim.current == nil ? 1 : 0)
                    Orb(size: 6).opacity(sim.current == nil ? 0 : 1)
                }
                .frame(width: 8)
                Text(sim.current ?? "Sleeps after 10 quiet minutes")
                    .font(sim.current == nil ? Typeface.sans(12) : Typeface.mono(11))
                    .foregroundStyle(sim.current == nil ? palette.secondary : palette.ink)
                    .lineLimit(1)
                Spacer(minLength: 6)
                Text("4 CPUs · 4 GB").font(Typeface.sans(11)).foregroundStyle(palette.faint)
            }
            if alwaysOpen || sim.working {
                TerminalText(lines: sim.terminal, cursor: sim.current != nil)
                    .frame(height: height)
                    .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .bottom)))
                Text("/work  ←  ~/Code/kuri-notes")
                    .font(Typeface.mono(10.5))
                    .foregroundStyle(palette.faint)
                    .transition(.opacity)
            }
        }
    }
}

/// A small terminal in the code blocks' colours, following its last line.
struct TerminalText: View {
    let lines: [TermLine]
    let cursor: Bool
    @Environment(\.palette) private var palette

    var body: some View {
        let term = Term(dark: palette.dark)
        let shape = RoundedRectangle(cornerRadius: 7, style: .continuous)
        ScrollView {
            VStack(alignment: .leading, spacing: 1.5) {
                ForEach(lines) { line in
                    Group {
                        if line.kind == .prompt {
                            Text("\(Text("$ ").foregroundStyle(term.green))\(Text(line.text.dropFirst(2)).foregroundStyle(term.fg))")
                        } else {
                            Text(line.text).foregroundStyle(color(line.kind, term))
                        }
                    }
                    .transition(.opacity.combined(with: .offset(y: 4)))
                }
                if cursor { Cursor(color: term.fg) }
            }
            .font(Typeface.mono(10.5))
            .lineLimit(1)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(8)
        }
        .defaultScrollAnchor(.bottom)
        .defaultScrollAnchor(.bottom, for: .sizeChanges)
        .background(shape.fill(term.bg))
        .overlay(shape.strokeBorder(palette.ink.opacity(palette.dark ? 0.08 : 0.07), lineWidth: 1))
        .clipShape(shape)
    }

    private func color(_ kind: TermLine.Kind, _ term: Term) -> Color {
        switch kind {
        case .fail: term.red
        case .pass: term.green
        default: term.dim
        }
    }
}

struct Cursor: View {
    let color: Color

    var body: some View {
        TimelineView(.periodic(from: .now, by: Pace.blink)) { context in
            let on = Int(context.date.timeIntervalSinceReferenceDate / Pace.blink) % 2 == 0
            Rectangle().fill(color).frame(width: 6, height: 11).opacity(on ? 0.85 : 0)
        }
    }
}

/// The Everforest colours the code blocks use: Higure dark, Yoake light.
struct Term {
    let dark: Bool
    var bg: Color { dark ? rgb(0x131313) : rgb(0xFFFAEE) }
    var fg: Color { dark ? rgb(0xD3C6AA) : rgb(0x5C6A72) }
    var dim: Color { dark ? rgb(0xA79C86) : rgb(0x829181) }
    var red: Color { dark ? rgb(0xE67E80) : rgb(0xF85552) }
    var green: Color { dark ? rgb(0xA7C080) : rgb(0x8DA101) }
    var yellow: Color { dark ? rgb(0xDBBC7F) : rgb(0xDFA000) }
}

func rgb(_ v: UInt32) -> Color {
    Color(red: Double((v >> 16) & 0xFF) / 255, green: Double((v >> 8) & 0xFF) / 255, blue: Double(v & 0xFF) / 255)
}

// MARK: - The chat beside it (simplified)

struct Chat: View {
    @Environment(Sim.self) private var sim
    @Environment(\.palette) private var palette

    var body: some View {
        ZStack(alignment: .bottom) {
            palette.background
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    UserCard(text: sim.turns.first?.prompt ?? "")
                        .padding(.bottom, 6)
                    ForEach(sim.steps.prefix(3)) { ToolLine(step: $0) }
                    Text(markdown(sim.replies[0])).font(Typeface.serif(15)).foregroundStyle(palette.ink).lineSpacing(4)
                    ForEach(sim.steps.dropFirst(3)) { ToolLine(step: $0) }
                    ForEach(sim.replies.dropFirst(), id: \.self) { reply in
                        Text(markdown(reply)).font(Typeface.serif(15)).foregroundStyle(palette.ink).lineSpacing(4)
                            .transition(.opacity)
                    }
                    if sim.running {
                        HStack(spacing: 8) {
                            Orb(size: 7)
                            Text(sim.current.map { "Running \($0.split(separator: " ").first ?? "")" } ?? "Thinking")
                                .font(Typeface.sans(13))
                                .foregroundStyle(palette.secondary)
                        }
                        .transition(.opacity)
                    }
                }
                .frame(maxWidth: 680, alignment: .leading)
                .padding(.horizontal, 32)
                .padding(.top, 60)
                .padding(.bottom, 150)
                .frame(maxWidth: .infinity)
            }
            .defaultScrollAnchor(.bottom, for: .sizeChanges)
            ComposerMock()
                .frame(maxWidth: 700)
                .padding(.horizontal, 22)
                .padding(.bottom, 22)
        }
    }

    private func markdown(_ text: String) -> AttributedString {
        (try? AttributedString(markdown: text)) ?? AttributedString(text)
    }
}

struct UserCard: View {
    let text: String
    @Environment(\.palette) private var palette

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
        Text(text)
            .font(Typeface.sans(14.5))
            .foregroundStyle(palette.ink)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 14)
            .padding(.vertical, 11)
            .background(shape.fill(palette.card))
            .overlay(shape.strokeBorder(palette.ink.opacity(palette.dark ? 0.06 : 0.05), lineWidth: 1))
            .shadow(color: palette.shadow.opacity(palette.dark ? 0.4 : 0.08), radius: 6, y: 3)
    }
}

struct ToolLine: View {
    let step: Step
    @Environment(\.palette) private var palette

    var body: some View {
        HStack(spacing: 8) {
            MarkIcon(mark: step.kind == .shell ? .terminal : step.kind == .plan ? .checklist : .bookmark, size: 13, color: palette.faint)
            Text(step.title).lineLimit(1)
            if step.running { Orb(size: 6) }
        }
        .font(Typeface.sans(13))
        .foregroundStyle(palette.secondary)
        .transition(.opacity.combined(with: .offset(y: 6)))
    }
}

struct ComposerMock: View {
    @Environment(Sim.self) private var sim
    @Environment(\.palette) private var palette

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
        VStack(alignment: .leading, spacing: 8) {
            Text("Ask anything").font(Typeface.sans(14.5)).foregroundStyle(palette.faint).padding(.horizontal, 5)
            HStack(spacing: 0) {
                QuietButton(glyph: .folder, label: "kuri-notes") {}
                Spacer()
                Text("\(short(sim.used)) / \(short(sim.window))")
                    .font(Typeface.sans(12).monospacedDigit())
                    .foregroundStyle(palette.faint)
                    .padding(.horizontal, 8)
                HStack(spacing: 4) {
                    Text("qwen3.5:9b")
                    PencilIcon(glyph: .chevron, size: 10, color: palette.faint)
                }
                .font(Typeface.sans(12.5))
                .foregroundStyle(palette.secondary)
                .padding(.horizontal, 8)
                ZStack {
                    Circle().fill(palette.accentFill)
                    if sim.running {
                        RoundedRectangle(cornerRadius: 2).fill(.white).frame(width: 9, height: 9)
                    } else {
                        PencilIcon(glyph: .arrowUp, size: 15, color: .white, weight: 1.8)
                    }
                }
                .frame(width: 28, height: 28)
                .padding(.leading, 4)
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 13)
        .padding(.bottom, 9)
        .background {
            ZStack {
                shape.fill(.ultraThinMaterial)
                shape.fill(palette.composer.opacity(0.88))
                shape.strokeBorder(palette.ink.opacity(palette.dark ? 0.06 : 0.05), lineWidth: 1)
            }
        }
        .background { OuterShadow(shape: shape, color: palette.shadow.opacity(palette.dark ? 0.35 : 0.07), radius: 14, y: 6) }
    }
}

struct FakeSidebar: View {
    @State private var selection: String? = "Fix the ISO week parser"

    var body: some View {
        List(selection: $selection) {
            ForEach(["Fix the ISO week parser", "Sourdough timings", "Rust vs Swift for a CLI", "Trip notes: Kyoto"], id: \.self) {
                Text($0).font(Typeface.sans(13)).tag($0)
            }
        }
        .listStyle(.sidebar)
    }
}

// MARK: - More pencil marks

/// Marks the app's `Glyph` doesn't have yet, drawn the same way.
enum Mark {
    case terminal, checklist, gauge, branch, box, inspector, bookmark, search

    var strokes: [[CGPoint]] {
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x, y: y) }
        func ring(_ x: CGFloat, _ y: CGFloat, _ r: CGFloat, from: Double = 0, to: Double = 2 * .pi, steps: Int = 12) -> [CGPoint] {
            (0...steps).map { k in
                let a = from + (to - from) * Double(k) / Double(steps)
                return p(x + r * CGFloat(cos(a)), y + r * CGFloat(sin(a)))
            }
        }
        switch self {
        case .terminal:
            return [[p(3.5, 5.5), p(20.5, 5.5), p(20.5, 18.5), p(3.5, 18.5), p(3.5, 5.4)],
                    [p(7.5, 9.5), p(10.5, 12), p(7.5, 14.5)], [p(12.5, 14.5), p(16.5, 14.5)]]
        case .checklist:
            return [[p(4, 7), p(5.8, 8.8), p(8.6, 5.4)], [p(11.5, 7.2), p(20, 7.2)],
                    [p(4, 12.6), p(5.8, 14.4), p(8.6, 11)], [p(11.5, 12.8), p(20, 12.8)],
                    ring(6.2, 18.3, 1.7, steps: 10), [p(11.5, 18.4), p(20, 18.4)]]
        case .gauge:
            return [ring(12, 15.5, 8, from: .pi, to: 2 * .pi, steps: 12), [p(4, 15.5), p(20, 15.5)], [p(12, 15.5), p(15.8, 10.2)]]
        case .branch:
            return [ring(7, 5.5, 2, steps: 10), ring(7, 18.5, 2, steps: 10), ring(17, 7.5, 2, steps: 10),
                    [p(7, 7.6), p(7, 16.4)], [p(17, 9.6), p(16.6, 12.2), p(13.6, 13.9), p(7.4, 15.2)]]
        case .box:
            return [[p(12, 3.5), p(19.5, 7.5), p(19.5, 16.5), p(12, 20.5), p(4.5, 16.5), p(4.5, 7.5), p(12, 3.4)],
                    [p(4.8, 7.7), p(12, 11.6), p(19.2, 7.7)], [p(12, 11.6), p(12, 20.2)]]
        case .inspector:
            return [[p(4, 5.5), p(20, 5.5), p(20, 18.5), p(4, 18.5), p(4, 5.4)], [p(14.5, 5.9), p(14.5, 18.2)]]
        case .bookmark:
            return [[p(7, 4.5), p(17, 4.5), p(17, 19.5), p(12, 15.5), p(7, 19.5), p(7, 4.4)]]
        case .search:
            return [ring(10.5, 10.5, 5.5, steps: 14), [p(14.6, 14.6), p(19.5, 19.5)]]
        }
    }
}

/// `PencilShape`'s drawing, for any strokes.
struct Sketchy: Shape {
    let strokes: [[CGPoint]]
    var seed: Double = 0
    var wobble: CGFloat = 0.42

    func path(in rect: CGRect) -> Path {
        let s = min(rect.width, rect.height) / 24
        let origin = CGPoint(x: rect.midX - 12 * s, y: rect.midY - 12 * s)
        var path = Path()
        for (k, stroke) in strokes.enumerated() {
            let dense = densify(stroke, step: 2.4)
            let points = dense.enumerated().map { i, pt -> CGPoint in
                let amount = wobble * (i == 0 || i == dense.count - 1 ? 0.5 : 1)
                let jx = noise(Double(i) + Double(k) * 31 + seed) * amount
                let jy = noise(Double(i) * 1.7 + Double(k) * 17 + seed + 5) * amount
                return CGPoint(x: origin.x + (pt.x + jx) * s, y: origin.y + (pt.y + jy) * s)
            }
            guard points.count > 1 else { continue }
            path.move(to: points[0])
            if points.count > 2 {
                for i in 1..<(points.count - 1) {
                    let next = points[i + 1]
                    path.addQuadCurve(to: CGPoint(x: (points[i].x + next.x) / 2, y: (points[i].y + next.y) / 2), control: points[i])
                }
            }
            path.addLine(to: points[points.count - 1])
        }
        return path
    }

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

    private func noise(_ x: Double) -> CGFloat {
        let v = sin(x * 12.9898 + 78.233) * 43758.5453
        return CGFloat((v - v.rounded(.down)) * 2 - 1)
    }
}

struct MarkIcon: View {
    let mark: Mark
    var size: CGFloat = 15
    var color: Color = .primary
    var weight: CGFloat = 1.4

    var body: some View {
        ZStack {
            Sketchy(strokes: mark.strokes)
                .stroke(color.opacity(0.92), style: StrokeStyle(lineWidth: weight, lineCap: .round, lineJoin: .round))
            Sketchy(strokes: mark.strokes, seed: 9, wobble: 0.6)
                .stroke(color.opacity(0.32), style: StrokeStyle(lineWidth: weight * 0.55, lineCap: .round, lineJoin: .round))
        }
        .frame(width: size, height: size)
    }
}
