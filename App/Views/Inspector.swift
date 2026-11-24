import AppKit
import KuriAgent
import KuriConfig
import KuriCore
import KuriSandbox
import KuriStore
import KuriTools
import SwiftUI

// The right sidebar (docs/ui.md, item 6; tried in Sketches/Inspector.swift):
// what the selected conversation is doing and where it stands. Everything
// here is derived from the conversation's items and the engine's events,
// except git, which is read from the attached folders.

/// The inspector's sections.
enum InspectorPane: String {
    case steps = "Steps", tasks = "Tasks", context = "Context", git = "Git", sandbox = "Sandbox"

    /// The name shown in its header (`rawValue` keys its stored state).
    var title: LocalizedStringKey {
        switch self {
        case .steps: "Steps"
        case .tasks: "Tasks"
        case .context: "Context"
        case .git: "Git"
        case .sandbox: "Sandbox"
        }
    }

    var glyph: Glyph {
        switch self {
        case .steps: .terminal
        case .tasks: .checklist
        case .context: .gauge
        case .git: .branch
        case .sandbox: .box
        }
    }
}

struct InspectorView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.palette) private var palette
    /// Bumped when Kuri comes back to the front: files may have changed.
    @State private var activations = 0
    /// The first git read since the inspector opened has happened.
    @State private var settled = false

    var body: some View {
        sections
        .background(surface.ignoresSafeArea())
        .task(id: GitKey(folders: model.folders.map(\.path), results: model.items.count,
                         running: model.isSelectedRunning, activations: activations)) {
            await loadRepositories()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            activations += 1
        }
    }

    /// One box per section, in a column; the sandbox pinned at the bottom.
    private var sections: some View {
        ScrollView {
            VStack(spacing: 8) {
                InspectorSection(pane: .steps) { StepsPane() }
                InspectorSection(pane: .tasks) { TasksPane() }
                InspectorSection(pane: .context) { ContextPane() }
                if !model.currentRepositories.isEmpty {
                    InspectorSection(pane: .git) { GitPane() }
                        .transition(.opacity)
                }
            }
            .padding(.horizontal, 10)
            .padding(.top, 10)
            .padding(.bottom, 16)
        }
        // Right from the column's top edge: nothing sits above the cards
        // (the toggle is over the chat).
        .ignoresSafeArea(edges: .top)
        .scrollEdgeEffectStyle(.soft, for: .top)
        // The sandbox stays in view at the bottom, as the composer does in
        // the chat: it's what moves while the model works.
        .safeAreaInset(edge: .bottom, spacing: 0) {
            InspectorSection(pane: .sandbox) { SandboxPane() }
                .padding(.horizontal, 10)
                .padding(.top, 14)
                .padding(.bottom, 10)
                .background {
                    LinearGradient(stops: [.init(color: surface.opacity(0), location: 0), .init(color: surface, location: 0.3)],
                                   startPoint: .top, endPoint: .bottom)
                }
        }
    }

    /// Warm like the chat, a step off it: the native inspector is a cool grey.
    private var surface: Color { palette.inspector }

    private func loadRepositories() async {
        var found = model.repositories
        for folder in model.folders {
            found[folder.path] = await RepositoryStatus.read(at: folder.path)
        }
        guard !Task.isCancelled else { return }
        defer { settled = true }
        guard found != model.repositories else { return }
        // Not while the inspector slides open: a box growing in the middle
        // of the slide makes both stutter.
        withAnimation(settled ? Tune.move : nil) { model.repositories = found }
    }

    private struct GitKey: Hashable {
        let folders: [String]
        let results: Int
        let running: Bool
        let activations: Int
    }
}

extension AppModel {
    /// The selected conversation's folders that are repositories, with their status.
    var currentRepositories: [(folder: ConversationFolder, status: RepositoryStatus)] {
        folders.compactMap { folder in repositories[folder.path].map { (folder, $0) } }
    }
}

// MARK: - Frame

/// A box per section, its header folding it; folded, the header still
/// says something (`InspectorAccessory`).
private struct InspectorSection<Content: View>: View {
    let pane: InspectorPane
    @ViewBuilder var content: Content
    @Environment(\.palette) private var palette
    @AppStorage private var open: Bool

    init(pane: InspectorPane, @ViewBuilder content: () -> Content) {
        self.pane = pane
        self.content = content()
        _open = AppStorage(wrappedValue: true, "inspectorOpen.\(pane.rawValue)")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // A button, so the keyboard and VoiceOver can fold it too.
            Button { withAnimation(Tune.move) { open.toggle() } } label: {
                HStack(spacing: 7) {
                    PencilIcon(glyph: pane.glyph, size: 14, color: palette.secondary, weight: 1.4)
                    Text(pane.title).font(Typeface.sans(13).weight(.medium)).foregroundStyle(palette.ink)
                    Spacer(minLength: 6)
                    InspectorAccessory(pane: pane)
                    PencilIcon(glyph: .chevron, size: 10, color: palette.faint)
                        .rotationEffect(.degrees(open ? 0 : -90))
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityAddTraits(.isHeader)
            .accessibilityValue(open ? Text("Expanded") : Text("Collapsed"))
            if open {
                content
                    .padding(.horizontal, 10)
                    .padding(.bottom, 10)
                    .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .clipped()
        .modifier(InspectorBox())
    }
}

/// A box resting on the inspector: a warm, solid fill (the pinned sandbox
/// hides what scrolls under it), a hairline, a soft contact shadow.
struct InspectorBox: ViewModifier {
    @Environment(\.palette) private var palette

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
        content
            // The shadow is the solid fill's: on the whole box it would be
            // drawn offscreen, text and all, at every frame of a resize.
            .background(shape.fill(palette.inspectorBox)
                .shadow(color: palette.shadow.opacity(palette.dark ? 0.25 : 0.05), radius: 1.5, y: 1))
            .overlay(shape.strokeBorder(palette.ink.opacity(palette.dark ? 0.07 : 0.06), lineWidth: 1))
    }
}

private struct InspectorAccessory: View {
    let pane: InspectorPane
    @Environment(AppModel.self) private var model
    @Environment(\.palette) private var palette

    var body: some View {
        Group {
            switch pane {
            case .steps:
                let steps = model.inspectorTurns.flatMap(\.steps)
                let commands = steps.filter { $0.isShell }.count
                if !steps.isEmpty {
                    Text(commands > 0 ? (commands == 1 ? "1 command" : "\(commands) commands")
                                      : (steps.count == 1 ? "1 step" : "\(steps.count) steps"))
                }
            case .tasks:
                let tasks = model.taskList
                if !tasks.isEmpty { Text("\(tasks.filter { $0.status == .completed }.count)/\(tasks.count)") }
            case .context:
                if let usage = model.contextUsage, model.selection != nil {
                    if let window = usage.window, window > 0 {
                        Text("\(Int((Double(usage.tokens) / Double(window) * 100).rounded()))%")
                    } else {
                        Text("≈ \(TokenCount.short(usage.tokens))")
                    }
                }
            case .git:
                let repositories = model.currentRepositories
                let changes = repositories.reduce(0) { $0 + $1.status.changes.count }
                if !repositories.isEmpty { Text(changes == 1 ? "1 change" : "\(changes) changes") }
            case .sandbox:
                switch SandboxState(model) {
                case .running: HStack(spacing: 4) { Orb(size: 6); Text("Running") }
                case .awake: Text("Awake")
                case .asleep: Text("Asleep")
                case .unavailable: Text("Off")
                }
            }
        }
        .font(Typeface.sans(11.5).monospacedDigit())
        .foregroundStyle(palette.dim)
        .contentTransition(.opacity)
        .animation(Tune.status, value: model.contextUsage?.tokens)
    }
}

/// Quiet text for a section with nothing to show yet.
private struct Quiet: View {
    let text: LocalizedStringKey
    @Environment(\.palette) private var palette

    init(_ text: LocalizedStringKey) { self.text = text }

    var body: some View {
        Text(text)
            .font(Typeface.sans(12))
            .foregroundStyle(palette.dim)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
    }
}

// MARK: - Steps

/// A message of the user's and the tool calls that followed it.
struct InspectorTurn: Identifiable, Equatable {
    let id: UUID
    let prompt: String?
    let date: Date
    var steps: [InspectorStep]

    /// The conversation's tool calls, grouped under the message before them.
    /// Built when the items change, not on every render; `summary` keeps
    /// each call's decoded arguments, so a new item doesn't decode them all
    /// again.
    static func turns(from items: [Item], summary: (ToolCall) -> ToolSummary) -> [InspectorTurn] {
        var results: [String: (result: ToolResult, date: Date)] = [:]
        for item in items {
            if case .toolResult(let result) = item.payload { results[result.callID] = (result, item.createdAt) }
        }
        var turns: [InspectorTurn] = []
        for item in items {
            switch item.payload {
            case .message(let message) where message.role == .user:
                turns.append(InspectorTurn(id: item.id, prompt: message.text, date: item.createdAt, steps: []))
            case .toolCall(let call):
                let found = results[call.id]
                let step = InspectorStep(id: call.id, summary: summary(call), result: found?.result,
                                         seconds: found.map { $0.date.timeIntervalSince(item.createdAt) })
                if turns.isEmpty { turns.append(InspectorTurn(id: item.id, prompt: nil, date: item.createdAt, steps: [])) }
                turns[turns.count - 1].steps.append(step)
            default:
                continue
            }
        }
        return turns
    }
}

/// One tool call, as the inspector lists it.
struct InspectorStep: Identifiable, Equatable {
    let id: String
    let summary: ToolSummary
    let result: ToolResult?
    let seconds: Double?
    /// The command's output (without its status line), the plan, or the
    /// tool's result. While a command runs, its output is `liveOutput`.
    let output: String
    let exitCode: Int?
    let timedOut: Bool

    init(id: String, summary: ToolSummary, result: ToolResult?, seconds: Double?) {
        self.id = id
        self.summary = summary
        self.result = result
        self.seconds = seconds
        var exitCode: Int?
        var timedOut = false
        var output = result?.output ?? ""
        if summary.isShell, let result {
            // "Exit code 1." or "Timed out after 120 s; …", then the output.
            let lines = result.output.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
            let status = lines.first.map(String.init) ?? ""
            if status.hasPrefix("Exit code "), let code = Int(status.dropFirst(10).dropLast()) { exitCode = code }
            timedOut = status.hasPrefix("Timed out")
            output = lines.count > 1 ? String(lines[1]) : ""
            if output == "(no output)" { output = "" }
        } else if !summary.tasks.isEmpty {
            output = summary.tasks.map { ($0.status == .completed ? "✓ " : $0.status == .inProgress ? "→ " : "· ") + $0.content }
                .joined(separator: "\n")
        }
        self.exitCode = exitCode
        self.timedOut = timedOut
        self.output = output
    }

    var isShell: Bool { summary.isShell }
    var title: String { summary.title(finished: result != nil) }
    var failed: Bool { timedOut || (exitCode.map { $0 != 0 } ?? false) || (result?.isError ?? false) }
}

/// Every tool call, turn by turn; commands up front, the rest quieter.
private struct StepsPane: View {
    /// How many of the latest steps show until Show all.
    static let latest = 6
    @Environment(AppModel.self) private var model
    @Environment(\.palette) private var palette
    @AppStorage("inspectorCommandsOnly") private var commandsOnly = false
    @State private var showAll = false

    var body: some View {
        let turns = model.inspectorTurns
        let isLive = model.isSelectedRunning
        let all = turns.flatMap(\.steps)
        let visible = all.filter { !commandsOnly || $0.isShell }
        let shownIDs = Set((showAll ? visible : Array(visible.suffix(Self.latest))).map(\.id))
        // Lazy: a long chat has hundreds of steps, and only those in view
        // need building (eager, 200 commands held about 12 MB).
        LazyVStack(alignment: .leading, spacing: 1) {
            if all.isEmpty {
                Quiet("Tool calls and commands show up here")
            } else {
                HStack(spacing: 2) {
                    Pill(title: "All", on: !commandsOnly) { commandsOnly = false }
                    Pill(title: "Commands", on: commandsOnly) { commandsOnly = true }
                    Spacer()
                    if shownIDs.count < visible.count {
                        Button("Show all \(visible.count)") { withAnimation(Tune.move) { showAll = true } }
                            .buttonStyle(.plain)
                            .font(Typeface.sans(11.5))
                            .foregroundStyle(palette.secondary)
                    }
                }
                .padding(.bottom, 4)
                ForEach(turns) { turn in
                    let rows = turn.steps.filter { shownIDs.contains($0.id) }
                    if !rows.isEmpty {
                        if let prompt = turn.prompt {
                            HStack(spacing: 6) {
                                Text("“\(prompt.split(whereSeparator: \.isNewline).first.map(String.init) ?? prompt)”")
                                    .lineLimit(1)
                                    .truncationMode(.tail)
                                Spacer(minLength: 4)
                                Text(turn.date, format: .dateTime.hour().minute()).monospacedDigit()
                            }
                            .font(Typeface.sans(11))
                            .foregroundStyle(palette.dim)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 3)
                        }
                        ForEach(rows) { step in
                            StepRow(step: step, running: step.result == nil && isLive)
                                .transition(.moving(.opacity.combined(with: .offset(y: 6))))
                        }
                    }
                }
            }
        }
        .animation(Tune.move, value: all.count)
        .onChange(of: model.selection) { showAll = false }
    }
}

private struct Pill: View {
    let title: LocalizedStringKey
    let on: Bool
    let action: () -> Void
    @Environment(\.palette) private var palette

    var body: some View {
        Button(action: { withAnimation(Tune.move) { action() } }) {
            Text(title)
                .font(Typeface.sans(11.5))
                .foregroundStyle(on ? palette.ink : palette.dim)
                .padding(.horizontal, 7)
                .padding(.vertical, 2.5)
                .background(Capsule().fill(palette.wash).opacity(on ? 1 : 0))
                .modifier(HoverWash(shape: Capsule()))
        }
        .buttonStyle(Squish())
    }
}

private struct StepRow: View {
    let step: InspectorStep
    let running: Bool
    @Environment(AppModel.self) private var model
    @Environment(\.palette) private var palette
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 7) {
                StepStatus(step: step, running: running).frame(width: 16)
                Text(step.title)
                    .font(step.isShell ? Typeface.mono(11.5) : Typeface.sans(12))
                    .foregroundStyle(step.isShell ? palette.ink : palette.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 4)
                if step.isShell, let seconds = step.seconds {
                    Text(Self.duration(seconds))
                        .font(Typeface.sans(10.5).monospacedDigit())
                        .foregroundStyle(palette.dim)
                }
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
            .modifier(HoverWash(shape: RoundedRectangle(cornerRadius: 6, style: .continuous)))
            .onTapGesture { toggle() }
            .help(hasDetail ? Text(step.isShell ? "Click to see the output" : "Click to see the details") : Text(verbatim: step.title))
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(hasDetail ? .isButton : [])
            .accessibilityAction { toggle() }
            if expanded {
                VStack(alignment: .leading, spacing: 4) {
                    if let command = step.summary.command, command != step.summary.commandLine {
                        // A multi-line command: the title showed its first line.
                        TerminalText(lines: TermLine.lines(callID: step.id + "-cmd", text: command), cursor: false)
                    }
                    if !output.isEmpty {
                        TerminalText(lines: TermLine.lines(callID: step.id, text: output), cursor: false)
                    }
                }
                .frame(maxHeight: 180)
                .padding(.leading, 26)
                .padding(.trailing, 2)
                .padding(.bottom, 4)
                .transition(.moving(.opacity.combined(with: .offset(y: -4))))
            }
        }
    }

    /// Only a call still waiting for its result reads the live output, so
    /// finished rows don't redraw as a command prints.
    private var output: String {
        step.result == nil ? model.liveOutput[step.id] ?? "" : step.output
    }

    private var hasDetail: Bool { !output.isEmpty }

    private func toggle() {
        if hasDetail { withAnimation(Tune.move) { expanded.toggle() } }
    }

    static func duration(_ seconds: Double) -> String {
        if seconds < 0.05 { return "<0.1s" }
        if seconds < 60 { return String(format: "%.1fs", seconds) }
        return "\(Int(seconds) / 60)m \(Int(seconds) % 60)s"
    }
}

/// Running, passed, failed (with its exit code), or the tool's own mark.
private struct StepStatus: View {
    let step: InspectorStep
    let running: Bool
    @Environment(\.palette) private var palette

    var body: some View {
        mark.accessibilityLabel(running ? Text("Running")
            : step.failed ? (step.timedOut ? Text("Timed out") : step.exitCode.map { Text("Failed with exit status \($0)") } ?? Text("Failed"))
            : Text("Done"))
    }

    @ViewBuilder private var mark: some View {
        if running {
            Orb(size: 6)
        } else if step.failed {
            Text(step.exitCode.map(String.init) ?? "!")
                .font(Typeface.mono(9.5).weight(.bold))
                .foregroundStyle(.white)
                .padding(.horizontal, 3)
                .frame(minWidth: 14, minHeight: 14)
                .background(Capsule().fill(palette.accentFill))
                .help(step.timedOut ? Text("Timed out") : step.exitCode.map { Text("Exit status \($0)") } ?? Text("Failed"))
        } else if step.isShell {
            PencilIcon(glyph: .check, size: 12, color: palette.faint)
        } else {
            PencilIcon(glyph: step.summary.glyph, size: 12, color: palette.faint, weight: 1.3)
        }
    }
}

// MARK: - Tasks

/// The plan, which the user can change: tick, rename, add, remove. Each
/// change replaces the whole list, like the model's own `tasklist` calls.
private struct TasksPane: View {
    @Environment(AppModel.self) private var model
    @Environment(\.palette) private var palette
    @State private var adding = false
    @State private var draft = ""
    @FocusState private var addFocused: Bool

    var body: some View {
        let tasks = model.taskList
        VStack(alignment: .leading, spacing: 1) {
            if tasks.isEmpty && !adding {
                Quiet("No plan yet: Kuri makes one for longer work")
            }
            ForEach(Array(tasks.enumerated()), id: \.offset) { index, task in
                TaskRow(task: task) { status in
                    var updated = tasks
                    updated[index].status = status
                    save(updated)
                } rename: { text in
                    var updated = tasks
                    updated[index].content = text
                    save(updated)
                } remove: {
                    var updated = tasks
                    updated.remove(at: index)
                    save(updated)
                }
                .transition(.moving(.opacity.combined(with: .offset(y: -4))))
            }
            if adding {
                HStack(spacing: 8) {
                    TaskCheck(status: .pending)
                    TextField("", text: $draft, prompt: Text(""))
                        .textFieldStyle(.plain)
                        .font(Typeface.sans(12.5))
                        .foregroundStyle(palette.ink)
                        .labelsHidden()
                        .focused($addFocused)
                        .onSubmit { add(to: tasks) }
                        .onExitCommand { adding = false; draft = "" }
                        .onChange(of: addFocused) { _, focused in if !focused { adding = false; draft = "" } }
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
                .disabled(model.selection == nil)
                Spacer()
                if model.hasPendingTasks {
                    Text("Kuri sees your changes at its next step")
                        .font(Typeface.sans(10.5))
                        .foregroundStyle(palette.dim)
                        .multilineTextAlignment(.trailing)
                        .transition(.opacity)
                }
            }
            .padding(.top, 4)
            .animation(Tune.status, value: model.hasPendingTasks)
        }
        .animation(Tune.move, value: tasks.count)
    }

    private func add(to tasks: [TaskListTool.Entry]) {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        draft = ""
        guard !text.isEmpty else {
            adding = false
            return
        }
        save(tasks + [TaskListTool.Entry(content: text, status: .pending)])
        addFocused = true
    }

    private func save(_ tasks: [TaskListTool.Entry]) {
        Task { await model.editTasks(tasks) }
    }
}

private struct TaskRow: View {
    let task: TaskListTool.Entry
    let setStatus: (TaskListTool.Entry.Status) -> Void
    let rename: (String) -> Void
    let remove: () -> Void
    @Environment(\.palette) private var palette
    @State private var editing = false
    @State private var hovering = false
    @State private var draft = ""
    @FocusState private var focused: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Button {
                withAnimation(Tune.press) { setStatus(task.status == .completed ? .pending : .completed) }
            } label: {
                // A 20-point target around the 14-point mark.
                TaskCheck(status: task.status).padding(3).contentShape(.rect)
            }
                .buttonStyle(Squish())
                .padding(-3)
                .padding(.top, 1)
                .help(task.status == .completed ? "Mark as not done" : "Mark as done")
                .accessibilityLabel(Text(task.content))
                .accessibilityValue(task.status == .completed ? Text("Done") : task.status == .inProgress ? Text("In progress") : Text("Not done"))
            if editing {
                TextField("", text: $draft, prompt: Text(""), axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(Typeface.sans(12.5))
                    .foregroundStyle(palette.ink)
                    .labelsHidden()
                    .focused($focused)
                    .onSubmit(commit)
                    .onExitCommand { editing = false }
                    .onChange(of: focused) { _, now in if !now { commit() } }
            } else {
                Text(task.content)
                    .font(Typeface.sans(12.5))
                    .foregroundStyle(task.status == .completed ? palette.dim : palette.ink)
                    .strikethrough(task.status == .completed, color: palette.faint)
                    .fontWeight(task.status == .inProgress ? .medium : .regular)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(.rect)
                    .onTapGesture(count: 2) { startEditing() }
                    .help("Double-click to edit")
            }
            Button(action: remove) {
                // Shown on hover; the context menu and VoiceOver reach it too.
                PencilIcon(glyph: .xmark, size: 10, color: palette.faint)
                    .frame(width: 20, height: 20)
                    .contentShape(.rect)
            }
            .buttonStyle(Squish())
            .padding(.vertical, -3)
            .opacity(hovering && !editing ? 1 : 0)
            .help("Remove")
            .accessibilityLabel(Text("Remove Task"))
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(palette.wash).opacity(hovering ? 1 : 0))
        .onHover { hovering = $0 }
        .animation(Tune.hover, value: hovering)
        // What hovering and double-clicking do, for touch and the keyboard.
        .contextMenu {
            Button(task.status == .completed ? "Mark as Not Done" : "Mark as Done") {
                setStatus(task.status == .completed ? .pending : .completed)
            }
            Button("Edit Task") { startEditing() }
            Divider()
            Button("Remove Task", role: .destructive, action: remove)
        }
        .accessibilityAction(named: Text("Edit Task")) { startEditing() }
    }

    private func startEditing() {
        draft = task.content
        editing = true
        focused = true
    }

    private func commit() {
        guard editing else { return }
        editing = false
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty, text != task.content { rename(text) }
    }
}

// MARK: - Context

/// What fills the window: one bar and its parts.
private struct ContextPane: View {
    @Environment(AppModel.self) private var model
    @Environment(\.palette) private var palette

    var body: some View {
        if let usage = model.contextUsage, model.selection != nil {
            content(usage)
        } else {
            Quiet("Fills up as the chat goes")
        }
    }

    private func content(_ usage: ContextUsage) -> some View {
        let parts = ContextPart.parts(of: usage, palette)
        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                Text(TokenCount.short(usage.tokens))
                    .font(Typeface.serif(20))
                    .foregroundStyle(palette.ink)
                    .contentTransition(.opacity)
                (usage.window.map { Text("of \(TokenCount.short($0)) tokens") } ?? Text("tokens, about"))
                    .font(Typeface.sans(12))
                    .foregroundStyle(palette.dim)
                Spacer()
            }
            if let window = usage.window, window > 0 {
                ContextBar(parts: parts, window: window, threshold: model.config.compactionThreshold)
            }
            Grid(horizontalSpacing: 14, verticalSpacing: 3) {
                ForEach(0..<(parts.count + 1) / 2, id: \.self) { row in
                    GridRow {
                        ForEach(parts.dropFirst(row * 2).prefix(2)) { part in
                            HStack(spacing: 6) {
                                Circle().fill(part.tone).frame(width: 7, height: 7)
                                Text(part.name).foregroundStyle(palette.secondary).lineLimit(1)
                                Spacer(minLength: 4)
                                Text(TokenCount.short(part.tokens))
                                    .foregroundStyle(palette.dim)
                                    .monospacedDigit()
                                    .contentTransition(.opacity)
                            }
                            .font(Typeface.sans(11.5))
                        }
                    }
                }
            }
            HStack {
                Text(usage.window == nil ? "Set contextWindow to compact automatically"
                                         : "Compacts at \(Int(model.config.compactionThreshold * 100))%")
                    .font(Typeface.sans(10.5))
                    .foregroundStyle(palette.dim)
                Spacer()
                Button { Task { await model.compactSelected() } } label: {
                    Text("Compact now").font(Typeface.sans(11.5)).padding(.horizontal, 9).padding(.vertical, 3.5)
                }
                .buttonStyle(SecondaryButton())
                .disabled(model.isSelectedBusy || model.items.isEmpty)
                .help("Summarize earlier messages now")
            }
        }
        .animation(Tune.status, value: usage.tokens)
    }
}

private struct ContextPart: Identifiable {
    var id: String { name }
    let name: String
    let tokens: Int
    let tone: Color

    static func parts(of usage: ContextUsage, _ palette: Palette) -> [ContextPart] {
        [ContextPart(name: String(localized: "System"), tokens: usage.system, tone: palette.faint.opacity(0.8)),
         ContextPart(name: String(localized: "Memory"), tokens: usage.memory, tone: CodeTheme(dark: palette.dark).yellow),
         ContextPart(name: String(localized: "Messages"), tokens: usage.messages, tone: palette.accentLight),
         ContextPart(name: String(localized: "Tool output"), tokens: usage.toolOutput, tone: palette.accent)]
    }
}

private struct ContextBar: View {
    let parts: [ContextPart]
    let window: Int
    /// Where compaction starts, as a share of the window.
    let threshold: Double
    @Environment(\.palette) private var palette

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            ZStack(alignment: .leading) {
                Capsule().fill(palette.wash)
                HStack(spacing: 1) {
                    ForEach(parts.filter { $0.tokens > 0 }) { part in
                        Rectangle()
                            .fill(part.tone)
                            .frame(width: max(1.5, min(width, width * CGFloat(part.tokens) / CGFloat(window))))
                    }
                }
                .frame(width: width, alignment: .leading)
                .clipShape(Capsule())
                Rectangle()
                    .fill(palette.faint)
                    .frame(width: 1.5, height: 8)
                    .offset(x: width * threshold)
                    .help("Kuri summarizes earlier messages here")
            }
        }
        .frame(height: 4)
    }
}

// MARK: - Git

/// Read-only: Kuri isn't a git client, this is so you know where things
/// stand. Shown only for folders that are repositories.
private struct GitPane: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(model.currentRepositories, id: \.folder.path) { repository in
                RepositoryView(folder: repository.folder, status: repository.status)
            }
        }
    }
}

private struct RepositoryView: View {
    let folder: ConversationFolder
    let status: RepositoryStatus
    /// How many changes show until Show all: a big change set would build
    /// hundreds of rows as the inspector opens.
    static let latest = 12
    @Environment(\.palette) private var palette
    @State private var showAll = false

    var body: some View {
        let code = CodeTheme(dark: palette.dark)
        let changes = showAll ? status.changes : Array(status.changes.prefix(Self.latest))
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                PencilIcon(glyph: .folder, size: 12, color: palette.faint)
                Text(URL(filePath: folder.path).lastPathComponent).font(Typeface.sans(12)).foregroundStyle(palette.secondary).lineLimit(1)
                Spacer(minLength: 6)
                PencilIcon(glyph: .branch, size: 12, color: palette.faint, weight: 1.3)
                Text(status.branch ?? "detached").font(Typeface.mono(11)).foregroundStyle(palette.ink).lineLimit(1).truncationMode(.middle)
                // Drawn arrows: the text face's ↑ and ↓ come from a
                // fallback font and sit clipped and off the baseline.
                if status.ahead > 0 {
                    count(status.ahead, down: false)
                        .help(status.ahead == 1 ? "1 commit not pushed yet" : "\(status.ahead) commits not pushed yet")
                }
                if status.behind > 0 {
                    count(status.behind, down: true)
                        .help(status.behind == 1 ? "1 commit to pull" : "\(status.behind) commits to pull")
                }
            }
            if status.changes.isEmpty {
                Quiet("No changes")
            } else {
                VStack(spacing: 1) {
                    ForEach(changes, id: \.path) { change in
                        HStack(spacing: 7) {
                            Text(String(change.kind.rawValue))
                                .font(Typeface.mono(10.5).weight(.bold))
                                .foregroundStyle(tone(change.kind, code))
                                .frame(width: 10)
                            path(change.path)
                            Spacer(minLength: 4)
                            HStack(spacing: 4) {
                                if let added = change.added, added > 0 { Text("+\(added)").foregroundStyle(code.green) }
                                if let removed = change.removed, removed > 0 { Text("−\(removed)").foregroundStyle(code.red) }
                            }
                            .font(Typeface.mono(10.5))
                        }
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3.5)
                        .modifier(HoverWash(shape: RoundedRectangle(cornerRadius: 6, style: .continuous)))
                        .help(change.path)
                    }
                }
                if changes.count < status.changes.count {
                    Button("Show all \(status.changes.count)") { withAnimation(Tune.move) { showAll = true } }
                        .buttonStyle(.plain)
                        .font(Typeface.sans(11.5))
                        .foregroundStyle(palette.secondary)
                        .padding(.horizontal, 6)
                }
            }
            if let commit = status.lastCommit {
                Text("\(commit.hash)  \(commit.subject) · \(commit.date, format: .relative(presentation: .named))")
                    .font(Typeface.sans(11))
                    .foregroundStyle(palette.dim)
                    .lineLimit(1)
                    .padding(.horizontal, 6)
            }
        }
    }

    private func path(_ path: String) -> some View {
        let parts = path.split(separator: "/")
        let directory = parts.dropLast().joined(separator: "/") + (parts.count > 1 ? "/" : "")
        return Text("\(Text(directory).foregroundStyle(palette.dim))\(Text(String(parts.last ?? "")).foregroundStyle(palette.ink))")
            .font(Typeface.sans(12))
            .lineLimit(1)
            .truncationMode(.head)
    }

    /// Commits ahead of (up) or behind (down) the branch's upstream.
    private func count(_ n: Int, down: Bool) -> some View {
        HStack(spacing: 1) {
            PencilIcon(glyph: .arrowUp, size: 10, color: palette.faint, weight: 1.4)
                .rotationEffect(.degrees(down ? 180 : 0))
            Text("\(n)").font(Typeface.sans(11).monospacedDigit()).foregroundStyle(palette.dim)
        }
    }

    private func tone(_ kind: RepositoryStatus.Change.Kind, _ code: CodeTheme) -> Color {
        switch kind {
        case .added: code.green
        case .deleted, .conflicted: code.red
        case .untracked: palette.dim
        default: code.yellow
        }
    }
}

// MARK: - Sandbox

/// What the conversation's container is doing.
private enum SandboxState {
    case running(String)
    case awake
    case asleep
    case unavailable(String)

    init(_ model: AppModel) {
        switch model.sandboxStatus {
        case .notInstalled: self = .unavailable(String(localized: "Not set up yet: Settings › Sandbox"))
        case .installing(let step, _): self = .unavailable(step)
        case .failed(let message): self = .unavailable(message)
        case .ready:
            if let step = model.runningCommand {
                self = .running(step.summary.commandLine)
            } else if let id = model.selection, model.sandboxUp.contains(id) {
                self = .awake
            } else {
                self = .asleep
            }
        }
    }
}

/// The VM at a glance, and a live tail of what runs in it. The
/// terminal opens only while the model works.
private struct SandboxPane: View {
    @Environment(AppModel.self) private var model
    @Environment(\.palette) private var palette

    var body: some View {
        let state = SandboxState(model)
        let settings = SandboxSettings(model.config.sandbox)
        let lines = terminal
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                // The orb only while a command runs: hidden, its timeline
                // would still redraw every frame, and SwiftUI keeps the
                // inspector's views alive after it closes.
                ZStack {
                    if isRunning(state) {
                        Orb(size: 6).transition(.opacity)
                    } else {
                        Circle().fill(palette.faint.opacity(0.6)).frame(width: 5, height: 5).transition(.opacity)
                    }
                }
                .frame(width: 8)
                Text(status(state, settings))
                    .font(isRunning(state) ? Typeface.mono(11) : Typeface.sans(12))
                    .foregroundStyle(isRunning(state) ? palette.ink : palette.secondary)
                    .lineLimit(1)
                Spacer(minLength: 6)
                Text("\(settings.cpus) CPUs · \(Self.memory(settings.memoryMiB))")
                    .font(Typeface.sans(11))
                    .foregroundStyle(palette.dim)
                    .fixedSize()
            }
            // Open once the running turn has run a command.
            if model.isSelectedRunning && !lines.isEmpty {
                TerminalText(lines: lines, cursor: isRunning(state))
                    .frame(height: 140)
                    .transition(.moving(.opacity.combined(with: .scale(scale: 0.96, anchor: .bottom))))
                ForEach(mounts, id: \.guestPath) { mount in
                    Text("\(mount.guestPath)  ←  \(mount.isScratch ? String(localized: "this chat's scratch folder") : Self.abbreviate(mount.hostPath))")
                        .font(Typeface.mono(10.5))
                        .foregroundStyle(palette.dim)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .transition(.opacity)
            }
        }
        .animation(Tune.move, value: model.isSelectedRunning)
    }

    /// What the model ran for the latest message, with the output, and the
    /// running command's so far. Not earlier turns': each command is a
    /// fresh shell, so older output isn't the sandbox's state.
    private var terminal: [TermLine] {
        let commands = (model.inspectorTurns.last?.steps ?? []).filter(\.isShell).suffix(6)
        return commands.flatMap { step -> [TermLine] in
            let output = step.result == nil ? model.liveOutput[step.id] ?? "" : step.output
            return TermLine.lines(callID: step.id + "-prompt", text: step.summary.command ?? "", prompt: true)
                + TermLine.lines(callID: step.id, text: output, tail: 60)
        }
    }


    private var mounts: [SandboxMount] {
        SandboxMounts.plan(folders: model.folders, scratch: URL(filePath: "/"))
    }

    private func isRunning(_ state: SandboxState) -> Bool {
        if case .running = state { true } else { false }
    }

    private func status(_ state: SandboxState, _ settings: SandboxSettings) -> String {
        switch state {
        case .running(let command): command
        case .awake: String(localized: "Awake · sleeps after \(settings.idleMinutes) quiet minutes")
        case .asleep: String(localized: "Asleep · wakes with the next command")
        case .unavailable(let reason): reason
        }
    }

    static func memory(_ mebibytes: Int) -> String {
        mebibytes % 1024 == 0 ? "\(mebibytes / 1024) GB" : String(format: "%.1f GB", Double(mebibytes) / 1024)
    }

    static func abbreviate(_ path: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path(percentEncoded: false)
        let trimmed = home.hasSuffix("/") ? String(home.dropLast()) : home
        return path.hasPrefix(trimmed) ? "~" + path.dropFirst(trimmed.count) : path
    }
}

/// A line in the small terminal.
struct TermLine: Identifiable {
    enum Kind { case prompt, output, fail, pass }

    let id: String
    let text: String
    let kind: Kind

    /// `text` split into lines, the last `tail` of them; ids stay stable as
    /// output grows, so lines don't redraw.
    static func lines(callID: String, text: String, prompt: Bool = false, tail: Int = .max) -> [TermLine] {
        guard !text.isEmpty else { return [] }
        let all = text.split(separator: "\n", omittingEmptySubsequences: false)
        let lines = (all.last?.isEmpty == true ? all.dropLast() : all[...])
        let start = max(lines.startIndex, lines.endIndex - tail)
        return lines[start...].enumerated().map { offset, line in
            let text = String(line)
            let kind: Kind = prompt && offset == 0 ? .prompt
                : text.hasPrefix("✘") || text.hasPrefix("error") ? .fail
                : text.hasPrefix("✔") ? .pass : .output
            return TermLine(id: "\(callID)-\(start + offset)", text: text, kind: kind)
        }
    }
}

/// A small terminal in the code blocks' colours, following its last line.
private struct TerminalText: View {
    let lines: [TermLine]
    let cursor: Bool
    @Environment(\.palette) private var palette

    var body: some View {
        let code = CodeTheme(dark: palette.dark)
        let shape = RoundedRectangle(cornerRadius: 7, style: .continuous)
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 1.5) {
                ForEach(lines) { line in
                    Group {
                        if line.kind == .prompt {
                            Text("\(Text("$ ").foregroundStyle(code.green))\(Text(line.text).foregroundStyle(code.text))")
                        } else {
                            Text(line.text).foregroundStyle(color(line.kind, code))
                        }
                    }
                    .transition(.opacity)
                }
                if cursor { Cursor(color: code.text) }
            }
            .font(Typeface.mono(10.5))
            .lineLimit(1)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(8)
        }
        .defaultScrollAnchor(.bottom)
        .defaultScrollAnchor(.bottom, for: .sizeChanges)
        .background(shape.fill(code.background))
        .overlay(shape.strokeBorder(palette.ink.opacity(palette.dark ? 0.08 : 0.07), lineWidth: 1))
        .clipShape(shape)
    }

    private func color(_ kind: TermLine.Kind, _ code: CodeTheme) -> Color {
        switch kind {
        case .fail: code.red
        case .pass: code.green
        default: code.text.opacity(0.82)
        }
    }
}

/// A block cursor, blinking while a command runs.
private struct Cursor: View {
    let color: Color
    /// Seconds on, then off.
    static let blink = 0.55

    var body: some View {
        TimelineView(.periodic(from: .now, by: Self.blink)) { context in
            let on = Int(context.date.timeIntervalSinceReferenceDate / Self.blink) % 2 == 0
            Rectangle().fill(color).frame(width: 6, height: 11).opacity(on ? 0.85 : 0)
        }
    }
}
