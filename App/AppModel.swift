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
    }

    private(set) var phase: Phase = .starting
    private(set) var engine: Engine?

    private(set) var conversations: [Conversation] = []
    var selection: UUID? {
        didSet { if selection != oldValue { Task { await loadSelection() } } }
    }

    /// Items of the selected conversation.
    private(set) var items: [Item] = []
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
    /// Estimated tokens the selected conversation fills, and the model's window if known.
    private(set) var contextUsage: (tokens: Int, window: Int?)?
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
    var errorMessage: String?
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

    /// The selected conversation's current plan, from its latest `tasklist` call.
    var taskList: [TaskListTool.Entry] {
        TaskListTool.current(in: items)
    }

    // MARK: Lifecycle

    func start() async {
        guard engine == nil else { return }
        do {
            let engine = try await Engine.open()
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
            await engine.resumePendingTurns()
        } catch {
            phase = .failed(error.localizedDescription)
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

    func delete(_ id: UUID) async {
        try? await engine?.delete(id)
    }

    func respond(to request: InputRequest, with response: InputResponse) async {
        await engine?.respond(to: request.id, with: response)
    }

    private func loadSelection() async {
        streamingText = ""
        streamingReasoning = ""
        guard let engine, let id = selection else {
            items = []
            lastTurn = nil
            turns = [:]
            contextUsage = nil
            folders = []
            return
        }
        items = (try? await engine.store.items(of: id)) ?? []
        folders = (try? await engine.folders(of: id)) ?? []
        await refreshTurnState()
    }

    private func refreshTurnState() async {
        guard let engine, let id = selection else { return }
        let all = (try? await engine.store.turns(of: id)) ?? []
        lastTurn = all.last
        turns = Dictionary(all.map { ($0.id, $0) }, uniquingKeysWith: { $1 })
        contextUsage = try? await engine.contextUsage(id)
    }

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

    func setGenerateTitles(_ enabled: Bool) async {
        do {
            try await engine?.setGenerateTitles(enabled)
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
            conversations.removeAll { $0.id == conversation.id }
            conversations.insert(conversation, at: conversations.firstIndex { !$0.pinned || conversation.pinned } ?? 0)

        case .conversationDeleted(let id):
            conversations.removeAll { $0.id == id }
            if selection == id { selection = nil }

        case .itemAdded(let item):
            guard item.conversationID == selection else { return }
            items.append(item)
            switch item.payload {
            case .message: streamingText = ""
            case .reasoning: streamingReasoning = ""
            case .compaction: Task { await refreshTurnState() }
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

        case .toolFinished:
            break

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
