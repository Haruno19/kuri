import Foundation
import KuriAgent
import KuriCore
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
    private(set) var inputRequests: [InputRequest] = []
    private(set) var models: [ModelRef] = []
    private(set) var tools: [ToolInfo] = []
    private(set) var memories: [Memory] = []
    var errorMessage: String?

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
            tools = await engine.toolCatalog()
            memories = try await engine.memories()
            phase = .ready
            Task { await observe(engine) }
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    private func observe(_ engine: Engine) async {
        for await event in engine.events() {
            handle(event)
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
                selection = try await engine.newConversation().id
            }
            guard let id = selection else { return }
            try await engine.send(text, to: id)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func setModel(_ model: ModelRef) async {
        guard let engine, var conversation = selectedConversation else { return }
        conversation.model = model
        try? await engine.update(conversation)
    }

    func cancel() async {
        guard let engine, let id = selection else { return }
        await engine.cancel(id)
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
            return
        }
        items = (try? await engine.store.items(of: id)) ?? []
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
            default: break
            }

        case .inference(let id, let event):
            guard id == selection else { return }
            switch event {
            case .textDelta(let delta): streamingText += delta
            case .reasoningDelta(let delta): streamingReasoning += delta
            default: break
            }

        case .turnStarted(let turn):
            running.insert(turn.conversationID)

        case .turnFinished(let id, _, let outcome):
            running.remove(id)
            if id == selection {
                streamingText = ""
                streamingReasoning = ""
            }
            if case .failed(let message) = outcome { errorMessage = message }

        case .toolFinished:
            break

        case .inputRequested(let request):
            inputRequests.append(request)

        case .inputResolved(let id):
            inputRequests.removeAll { $0.id == id }

        case .configReloaded:
            Task { models = await engine?.models ?? [] }

        case .configFailed(let message):
            errorMessage = message

        case .toolsChanged:
            Task { tools = await engine?.toolCatalog() ?? [] }

        case .memoriesChanged:
            Task { await reloadMemories() }
        }
    }
}
