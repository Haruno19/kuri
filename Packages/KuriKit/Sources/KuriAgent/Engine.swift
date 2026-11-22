import Foundation
import KuriConfig
import KuriCore
import KuriInference
import KuriStore
import KuriTools

/// The whole of Kuri behind one facade: configuration, storage, providers,
/// tools and running turns.
///
/// The app calls its methods and observes `events()`. Nothing here knows
/// about SwiftUI.
public actor Engine {
    public nonisolated let home: KuriHome
    public nonisolated let store: Store
    public private(set) var config: Config
    public private(set) var mcpConfig: MCPConfig
    public var limits = TurnLimits()

    private let registry: ToolRegistry
    private let broker: InteractionBroker
    private let broadcaster: EventBroadcaster
    private let factory: ProviderFactory
    private var providers: [String: any InferenceProvider] = [:]
    private var running: [UUID: Task<Void, Never>] = [:]
    private var watcher: Task<Void, Never>?

    /// Opens `~/.config/kuri` (creating it on first launch), loads the config and
    /// the database, and starts watching the config files.
    public static func open(home: KuriHome = .resolve()) async throws -> Engine {
        try home.prepare()
        let loader = ConfigLoader(home: home)
        let engine = Engine(
            home: home,
            store: try Store(url: home.database),
            config: try loader.loadConfig(),
            mcpConfig: try loader.loadMCP())
        try await engine.store.recoverInterruptedTurns()
        await engine.startWatching()
        return engine
    }

    init(home: KuriHome, store: Store, config: Config, mcpConfig: MCPConfig,
         tools: [any Tool] = BuiltInTools.all, factory: ProviderFactory = ProviderFactory()) {
        let broadcaster = EventBroadcaster()
        self.home = home
        self.store = store
        self.config = config
        self.mcpConfig = mcpConfig
        self.registry = ToolRegistry(tools)
        self.broadcaster = broadcaster
        self.broker = InteractionBroker(emit: { broadcaster.emit($0) })
        self.factory = factory
    }

    public nonisolated func events() -> AsyncStream<EngineEvent> {
        broadcaster.subscribe()
    }

    // MARK: Configuration

    public var models: [ModelRef] { config.declaredModels }

    public func reloadConfig() {
        let loader = ConfigLoader(home: home)
        do {
            config = try loader.loadConfig()
            mcpConfig = try loader.loadMCP()
            providers.removeAll()
            broadcaster.emit(.configReloaded)
        } catch {
            broadcaster.emit(.configFailed(error.localizedDescription))
        }
    }

    private func startWatching() {
        let changes = ConfigWatcher.changes(in: home)
        watcher = Task { [weak self] in
            for await _ in changes {
                await self?.reloadConfig()
            }
        }
    }

    private func provider(for ref: ModelRef) throws -> any InferenceProvider {
        if let cached = providers[ref.provider] { return cached }
        guard let providerConfig = config.providers[ref.provider] else {
            throw KuriError.unknownProvider(ref.provider)
        }
        let provider = try factory.make(name: ref.provider, config: providerConfig)
        providers[ref.provider] = provider
        return provider
    }

    // MARK: Conversations

    public func newConversation(model: ModelRef? = nil) async throws -> Conversation {
        let conversation = Conversation(model: model ?? config.defaultModel)
        try await store.createConversation(conversation)
        broadcaster.emit(.conversationUpdated(conversation))
        return conversation
    }

    public func update(_ conversation: Conversation) async throws {
        var conversation = conversation
        conversation.updatedAt = .now
        try await store.updateConversation(conversation)
        broadcaster.emit(.conversationUpdated(conversation))
    }

    public func delete(_ conversationID: UUID) async throws {
        cancel(conversationID)
        try await store.deleteConversation(conversationID)
        broadcaster.emit(.conversationDeleted(conversationID))
    }

    public func isRunning(_ conversationID: UUID) -> Bool {
        running[conversationID] != nil
    }

    // MARK: Turns

    /// Adds the user's message and starts a turn. Returns once the turn is
    /// running; follow it through `events()`.
    public func send(_ text: String, to conversationID: UUID) async throws {
        guard running[conversationID] == nil else {
            throw KuriError.provider("This conversation is already running.")
        }
        guard var conversation = try await store.conversation(conversationID) else {
            throw KuriError.database("No conversation with id \(conversationID).")
        }
        guard let model = conversation.model ?? config.defaultModel else {
            throw KuriError.invalidConfig(file: "config.json", reason: "no model selected and no defaultModel set")
        }
        let provider = try provider(for: model)

        let message = Item(conversationID: conversationID, payload: .message(Message(role: .user, text: text)))
        try await store.append(message)
        broadcaster.emit(.itemAdded(message))

        if conversation.title.isEmpty {
            // Placeholder until title generation with the utility model lands.
            conversation.title = Self.provisionalTitle(for: text)
        }
        conversation.model = model
        try await update(conversation)

        let turn = try await store.beginTurn(conversationID: conversationID, model: model)
        broadcaster.emit(.turnStarted(turn))

        let folders = try await store.folders(of: conversationID)
        let modelConfig = config.modelConfig(for: model)
        let runner = TurnRunner(
            conversationID: conversationID,
            turn: turn,
            provider: provider,
            modelConfig: ModelConfigSnapshot(maxOutputTokens: modelConfig?.maxOutputTokens,
                                             reasoningEffort: modelConfig?.reasoningEffort),
            instructions: Instructions.build(conversation: conversation, folders: folders,
                                             memories: try await store.memories()),
            folders: folders,
            registry: registry,
            store: store,
            interaction: broker,
            limits: limits,
            emit: { [broadcaster] in broadcaster.emit($0) })

        running[conversationID] = Task { [weak self] in
            _ = await runner.run()
            await self?.turnEnded(conversationID)
        }
    }

    public func cancel(_ conversationID: UUID) {
        running[conversationID]?.cancel()
    }

    public func respond(to requestID: UUID, with response: InputResponse) async {
        await broker.respond(to: requestID, with: response)
    }

    public func openInputRequests() async -> [InputRequest] {
        await broker.openRequests
    }

    private func turnEnded(_ conversationID: UUID) {
        running[conversationID] = nil
    }

    static func provisionalTitle(for text: String) -> String {
        let firstLine = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? text
        let trimmed = firstLine.trimmingCharacters(in: .whitespaces)
        return trimmed.count > 60 ? String(trimmed.prefix(57)) + "…" : trimmed
    }
}
