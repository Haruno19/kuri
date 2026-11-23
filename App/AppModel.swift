import AppKit
import Foundation
import KuriAgent
import KuriConfig
import KuriCore
import KuriMCP
import KuriSandbox
import KuriStore
import KuriTools
import Observation

/// The UI's view of the engine: a main-actor mirror of the state the views
/// need, kept current from `Engine.events()`.
@Observable
final class AppModel {
    enum Phase {
        case starting
        case ready
        case failed(String)

        var isReady: Bool {
            if case .ready = self { true } else { false }
        }
    }

    private(set) var phase: Phase = .starting
    private(set) var engine: Engine?

    private(set) var conversations: [Conversation] = []
    var selection: UUID? {
        didSet { if selection != oldValue { Task { await loadSelection() } } }
    }

    /// The conversation `items` and the turns belong to. It changes only
    /// once they're all loaded, so the transcript, rebuilt on it, never
    /// opens on the previous chat's items and then sees them swapped.
    private(set) var loadedConversation: UUID?
    /// Items of the selected conversation.
    private(set) var items: [Item] = [] {
        didSet { deriveFromItems() }
    }
    /// The selected conversation's tool calls, grouped by message, for the
    /// inspector, and its current plan. Read from `items` when they change,
    /// so views don't decode tool arguments on every render.
    private(set) var inspectorTurns: [InspectorTurn] = []
    private(set) var plan: [TaskListTool.Entry] = []
    /// Each call's summary, by call id: built once per call.
    @ObservationIgnored private var summaries: [String: ToolSummary] = [:]
    /// Live output of the selected conversation's running turn.
    private(set) var streamingText = ""
    private(set) var streamingReasoning = ""

    private(set) var running: Set<UUID> = []
    /// Messages waiting for each busy conversation's next step.
    private(set) var queues: [UUID: [QueuedMessage]] = [:]
    /// Conversations whose start is being summarized right now.
    private(set) var compacting: Set<UUID> = []
    /// Which fallback model took over a conversation's running turn, and why.
    private(set) var fallbackNotices: [UUID: String] = [:]
    /// The selected conversation's latest turn, for the Continue bar.
    private(set) var lastTurn: Turn?
    /// The selected conversation's turns, for each answer's time and tokens.
    private(set) var turns: [UUID: Turn] = [:]
    /// Estimated tokens the selected conversation fills, what fills them,
    /// and the model's window if known.
    private(set) var contextUsage: ContextUsage?
    /// What the selected conversation's running commands have printed so
    /// far, by call id, until their results arrive.
    private(set) var liveOutput: [String: String] = [:]
    /// Conversations whose sandbox container is up.
    private(set) var sandboxUp: Set<UUID> = []
    /// Task lists the user edited during a turn, shown until the turn
    /// takes them at its next step.
    private(set) var pendingTasks: [UUID: [TaskListTool.Entry]] = [:]
    private(set) var inputRequests: [InputRequest] = []
    private(set) var models: [ModelRef] = []
    private(set) var config = Config() {
        didSet { Self.apply(config.appearance) }
    }
    private(set) var tools: [ToolInfo] = []
    private(set) var memories: [Memory] = []
    private(set) var mcpServers: [MCPServerStatus] = []
    private(set) var sandboxStatus: SandboxStatus = .notInstalled
    /// Folders attached to the selected conversation.
    private(set) var folders: [ConversationFolder] = []
    /// Git status of attached folders that are repositories, by path. Kept
    /// here, not in the inspector, so the Git box is already there when the
    /// inspector opens again.
    var repositories: [String: RepositoryStatus] = [:]
    var errorMessage: String?
    /// The inspector is open (the main window's; ⌥⌘I). Not remembered:
    /// the window opens on the chat alone.
    var showsInspector = false
    /// The plan shows in the inspector's Tasks section rather than above the
    /// composer. Follows `showsInspector` once its slide is over
    /// (`toggleInspector()`).
    var planInInspector = false
    /// The model picked on the new-chat page, before a conversation exists.
    var draftModel: ModelRef?

    var selectedConversation: Conversation? {
        conversations.first { $0.id == selection }
    }

    var isSelectedRunning: Bool {
        selection.map(running.contains) ?? false
    }

    func isAwaitingInput(_ conversationID: UUID) -> Bool {
        inputRequests.contains { $0.conversationID == conversationID }
    }

    /// The selected conversation's current plan, from its latest `tasklist`
    /// call, or the user's edit waiting for the running turn.
    var taskList: [TaskListTool.Entry] {
        selection.flatMap { pendingTasks[$0] } ?? plan
    }

    /// The working indicator's words: the tool in progress, or thinking.
    var workingStatus: String {
        guard let last = inspectorTurns.last?.steps.last, last.result == nil else { return "Thinking" }
        return last.summary.status
    }

    /// The running command, if the selected conversation's turn is in one.
    var runningCommand: InspectorStep? {
        guard isSelectedRunning else { return nil }
        return inspectorTurns.last?.steps.last { $0.isShell && $0.result == nil }
    }

    /// A call's summary, built once per call.
    func summary(of call: ToolCall) -> ToolSummary {
        if let summary = summaries[call.id] { return summary }
        let summary = ToolSummary(call)
        summaries[call.id] = summary
        return summary
    }

    private func deriveFromItems() {
        inspectorTurns = InspectorTurn.turns(from: items, summary: summary(of:))
        plan = TaskListTool.current(in: items)
    }

    /// The user's edit is waiting for the running turn's next step.
    var hasPendingTasks: Bool {
        selection.map { pendingTasks[$0] != nil } ?? false
    }

    /// Replaces the plan with the user's version (from the inspector).
    func editTasks(_ entries: [TaskListTool.Entry]) async {
        guard let engine, let id = selection else { return }
        if running.contains(id) { pendingTasks[id] = entries }
        do {
            try await engine.editTaskList(entries, in: id)
        } catch {
            pendingTasks[id] = nil
            errorMessage = error.localizedDescription
        }
    }

    // MARK: Lifecycle

    func start() async {
        guard engine == nil else { return }
        do {
            let engine = try await Engine.open()
            try await attach(to: engine)
            await engine.resumePendingTurns()
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    /// A second model on an engine that's already running, with a
    /// selection of its own: the mini window's. It picks up what's in
    /// flight (running turns, open questions) and then follows events.
    func start(sharing engine: Engine) async {
        guard self.engine == nil else { return }
        do {
            try await attach(to: engine)
            running = await engine.runningConversations
            inputRequests = await engine.openInputRequests()
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    private func attach(to engine: Engine) async throws {
        self.engine = engine
        conversations = try await engine.store.conversations()
        models = await engine.models
        config = await engine.config
        tools = await engine.toolCatalog()
        memories = try await engine.memories()
        mcpServers = await engine.mcpServers()
        sandboxStatus = await engine.sandbox.status
        phase = .ready
        // Subscribe before resuming, so re-asked questions aren't missed.
        let events = engine.events()
        Task {
            for await event in events { handle(event) }
        }
    }

    // MARK: Conversations

    func newConversation() async {
        guard let engine else { return }
        do {
            let conversation = try await engine.newConversation()
            selection = conversation.id
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func send(_ text: String) async {
        guard let engine else { return }
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        do {
            if selection == nil {
                selection = try await engine.newConversation(model: draftModel).id
            }
            guard let id = selection else { return }
            try await engine.send(text, to: id)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Sends a composer's draft and empties it; whitespace alone isn't sent.
    /// While a turn runs, the message is queued for its next step.
    func submit(_ draft: inout String) {
        let text = draft
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        draft = ""
        Task { await send(text) }
    }

    /// The model the composer shows: the conversation's, or on the new-chat
    /// page the one picked there, else the default.
    var composerModel: ModelRef? {
        selection == nil ? draftModel ?? config.defaultModel : selectedConversation?.model ?? config.defaultModel
    }

    func setModel(_ model: ModelRef) async {
        guard selection != nil else {
            draftModel = model
            return
        }
        guard let engine, var conversation = selectedConversation else { return }
        conversation.model = model
        try? await engine.update(conversation)
    }

    var selectedQueue: [QueuedMessage] {
        selection.flatMap { queues[$0] } ?? []
    }

    func unqueue(_ message: QueuedMessage) async {
        guard let engine, let id = selection else { return }
        await engine.unqueue(message.id, in: id)
    }

    func cancel() async {
        guard let engine, let id = selection else { return }
        await engine.cancel(id)
    }

    /// Picks up after a failed, stopped or interrupted turn.
    /// Answers the last message again, replacing the previous answer.
    func retrySelected() async {
        guard let engine, let id = selection else { return }
        do {
            try await engine.retry(id)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func continueSelected() async {
        guard let engine, let id = selection else { return }
        do {
            try await engine.continueConversation(id)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func compactSelected() async {
        guard let engine, let id = selection else { return }
        do {
            try await engine.compact(id)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    var isSelectedBusy: Bool {
        selection.map { running.contains($0) || compacting.contains($0) } ?? false
    }

    func rename(_ id: UUID, to title: String) async {
        do {
            try await engine?.rename(id, to: title)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func delete(_ id: UUID) async {
        try? await engine?.delete(id)
    }

    func respond(to request: InputRequest, with response: InputResponse) async {
        await engine?.respond(to: request.id, with: response)
    }

    private func loadSelection() async {
        streamingText = ""
        streamingReasoning = ""
        liveOutput = [:]
        summaries = [:]
        guard let engine, let id = selection else {
            items = []
            lastTurn = nil
            turns = [:]
            contextUsage = nil
            folders = []
            loadedConversation = nil
            return
        }
        let loadedItems = (try? await engine.store.items(of: id)) ?? []
        let loadedFolders = (try? await engine.folders(of: id)) ?? []
        let sandboxRunning = await engine.isSandboxRunning(id)
        let loadedTurns = (try? await engine.store.turns(of: id)) ?? []
        // Picked another chat meanwhile: its own load takes over.
        guard selection == id else { return }
        // All at once, with no suspension in between: one update.
        items = loadedItems
        folders = loadedFolders
        if sandboxRunning { sandboxUp.insert(id) } else { sandboxUp.remove(id) }
        lastTurn = loadedTurns.last
        turns = Dictionary(loadedTurns.map { ($0.id, $0) }, uniquingKeysWith: { $1 })
        loadedConversation = id
        contextUsage = try? await engine.contextUsage(id)
    }

    private func refreshTurnState() async {
        guard let engine, let id = selection else { return }
        let all = (try? await engine.store.turns(of: id)) ?? []
        lastTurn = all.last
        turns = Dictionary(all.map { ($0.id, $0) }, uniquingKeysWith: { $1 })
        contextUsage = try? await engine.contextUsage(id)
    }

    private func refreshContextUsage() async {
        guard let engine, let id = selection else { return }
        contextUsage = try? await engine.contextUsage(id)
    }

    /// Characters of a running command's output kept for display.
    static let liveOutputLimit = 20_000

    func reconnect(mcpServer name: String) async {
        await engine?.reconnectMCPServer(name)
    }

    // MARK: Models

    /// The models a provider serves, for the registration combobox.
    func availableModels(provider: String) async throws -> [String] {
        guard let engine else { return [] }
        return try await engine.availableModels(provider: provider)
    }

    func register(_ model: ModelConfig, provider: String) async {
        do {
            try await engine?.register(model, provider: provider)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func unregister(model id: String, provider: String) async {
        do {
            try await engine?.unregister(model: id, provider: provider)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func setAPIKey(_ key: String?, provider: String) async {
        do {
            try await engine?.setAPIKey(key, provider: provider)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func setGenerateTitles(_ enabled: Bool) async {
        do {
            try await engine?.setGenerateTitles(enabled)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func setStartInBackground(_ enabled: Bool) async {
        do {
            try await engine?.setStartInBackground(enabled)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func setCompactAt(_ percent: Int) async {
        do {
            try await engine?.setCompactAt(percent)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func setMeadow(_ enabled: Bool) async {
        do {
            try await engine?.setMeadow(enabled)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func setAppearance(_ appearance: Appearance) async {
        do {
            try await engine?.setAppearance(appearance)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func setSandbox(image: String?, cpus: Int?, memoryMiB: Int?, idleMinutes: Int?) async {
        do {
            try await engine?.setSandbox(image: image, cpus: cpus, memoryMiB: memoryMiB, idleMinutes: idleMinutes)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func setDefaultModel(_ ref: ModelRef?) async {
        do {
            try await engine?.setDefaultModel(ref)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: Sandbox and folders

    func setUpSandbox() async {
        do {
            try await engine?.setUpSandbox()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Adds folders to the selected conversation, creating one if needed.
    func attach(_ urls: [URL]) async {
        guard let engine else { return }
        do {
            if selection == nil { selection = try await engine.newConversation(model: draftModel).id }
            guard let id = selection else { return }
            var updated = folders
            for url in urls where !updated.contains(where: { $0.path == url.path(percentEncoded: false) }) {
                updated.append(ConversationFolder(path: url.path(percentEncoded: false)))
            }
            try await engine.setFolders(updated, for: id)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func detach(_ folder: ConversationFolder) async {
        await updateFolders { $0.removeAll { $0.path == folder.path } }
    }

    func toggleReadOnly(_ folder: ConversationFolder) async {
        await updateFolders { folders in
            if let index = folders.firstIndex(where: { $0.path == folder.path }) { folders[index].readOnly.toggle() }
        }
    }

    private func updateFolders(_ change: (inout [ConversationFolder]) -> Void) async {
        guard let engine, let id = selection else { return }
        var updated = folders
        change(&updated)
        do {
            try await engine.setFolders(updated, for: id)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: Memory

    func changeMemories(_ changes: [MemoryChange]) async {
        do {
            try await engine?.changeMemories(changes)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func reloadMemories() async {
        memories = (try? await engine?.memories()) ?? memories
    }

    // MARK: Events

    private func handle(_ event: EngineEvent) {
        switch event {
        case .conversationUpdated(let conversation):
            // Same updatedAt (give or take the database's rounding): an edit
            // like a rename, which keeps its place.
            if let index = conversations.firstIndex(where: { $0.id == conversation.id }),
               abs(conversations[index].updatedAt.timeIntervalSince(conversation.updatedAt)) < 0.001 {
                conversations[index] = conversation
                break
            }
            conversations.removeAll { $0.id == conversation.id }
            conversations.insert(conversation, at: conversations.firstIndex { !$0.pinned || conversation.pinned } ?? 0)

        case .conversationDeleted(let id):
            conversations.removeAll { $0.id == id }
            if selection == id { selection = nil }

        case .itemAdded(let item):
            // The turn took the user's plan edit (or the model wrote a newer one).
            if case .toolCall(let call) = item.payload, call.name == "tasklist" {
                pendingTasks[item.conversationID] = nil
            }
            guard item.conversationID == selection else { return }
            items.append(item)
            switch item.payload {
            case .message: streamingText = ""
            case .reasoning: streamingReasoning = ""
            case .compaction: Task { await refreshTurnState() }
            // The inspector's context meter follows the turn as it goes.
            case .toolResult: Task { await refreshContextUsage() }
            default: break
            }

        case .itemsRemoved(let id, let removed):
            guard id == selection else { return }
            let gone = Set(removed)
            items.removeAll { gone.contains($0.id) }

        case .inference(let id, let event):
            guard id == selection else { return }
            switch event {
            case .textDelta(let delta): streamingText += delta
            case .reasoningDelta(let delta): streamingReasoning += delta
            default: break
            }

        case .turnStarted(let turn):
            running.insert(turn.conversationID)
            fallbackNotices[turn.conversationID] = nil
            if turn.conversationID == selection { lastTurn = turn }

        case .turnFinished(let id, _, _):
            running.remove(id)
            if id == selection {
                streamingText = ""
                streamingReasoning = ""
                Task { await refreshTurnState() }
            }

        case .modelFallback(let id, let from, let to, let reason):
            fallbackNotices[id] = "\(from) failed (\(reason)); \(to) took over."
            if id == selection {
                streamingText = ""
                streamingReasoning = ""
            }

        case .compacting(let id, let active):
            if active { compacting.insert(id) } else { compacting.remove(id) }

        case .toolOutput(let id, let callID, let text):
            guard id == selection else { return }
            // The tail is what the inspector shows; keep it bounded.
            var output = liveOutput[callID, default: ""] + text
            if output.count > Self.liveOutputLimit { output = String(output.suffix(Self.liveOutputLimit)) }
            liveOutput[callID] = output

        case .toolFinished(let id, let call, _):
            if id == selection { liveOutput[call.id] = nil }

        case .sandboxContainer(let id, let up):
            if up { sandboxUp.insert(id) } else { sandboxUp.remove(id) }

        case .inputRequested(let request):
            inputRequests.append(request)

        case .inputResolved(let id):
            inputRequests.removeAll { $0.id == id }

        case .configReloaded:
            Task {
                guard let engine else { return }
                models = await engine.models
                config = await engine.config
                await refreshTurnState()
            }

        case .configFailed(let message):
            errorMessage = message

        case .toolsChanged:
            Task { tools = await engine?.toolCatalog() ?? [] }

        case .memoriesChanged:
            Task { await reloadMemories() }

        case .mcpServersChanged(let servers):
            mcpServers = servers

        case .sandboxChanged(let status):
            sandboxStatus = status

        case .queueChanged(let id, let queue):
            queues[id] = queue.isEmpty ? nil : queue

        case .foldersChanged(let id, let updated):
            if id == selection {
                folders = updated
                Task { await refreshTurnState() }
            }
        }
    }
}

extension AppModel {
    /// The whole app follows `appearance`: windows, Settings and the menu
    /// bar panel. `nil` lets macOS decide.
    static func apply(_ appearance: Appearance?) {
        let name: NSAppearance.Name? = switch appearance ?? .system {
        case .system: nil
        case .light: .aqua
        case .dark: .darkAqua
        }
        let target = name.flatMap(NSAppearance.init(named:))
        let app = NSApplication.shared
        if app.appearance?.name != target?.name { app.appearance = target }
    }
}
