import Foundation
import KuriConfig
import KuriCore
import KuriInference
import KuriMCP
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
    private let mcp: MCPManager
    private let broker: InteractionBroker
    private let broadcaster: EventBroadcaster
    private let factory: ProviderFactory
    private var providers: [String: any InferenceProvider] = [:]
    /// Models listed by providers that have `discoverModels: true`.
    private var discovered: [String: [String]] = [:]
    private var discovery: Task<Void, Never>?
    private var running: [UUID: Task<Void, Never>] = [:]
    private var watcher: Task<Void, Never>?

    /// Opens `~/.config/kuri` (creating it on first launch), loads the
    /// config and the database, and starts watching the config files.
    public static func open(home: KuriHome = .resolve()) async throws -> Engine {
        try home.prepare()
        let loader = ConfigLoader(home: home)
        let engine = Engine(
            home: home,
            store: try Store(url: home.database),
            config: try loader.loadConfig(),
            mcpConfig: try loader.loadMCP())
        try await engine.store.recoverInterruptedTurns()
        await engine.start()
        return engine
    }

    init(home: KuriHome, store: Store, config: Config, mcpConfig: MCPConfig,
         tools: [any Tool] = BuiltInTools.all, factory: ProviderFactory = ProviderFactory()) {
        let broadcaster = EventBroadcaster()
        let registry = ToolRegistry(tools)
        self.home = home
        self.store = store
        self.config = config
        self.mcpConfig = mcpConfig
        self.registry = registry
        self.mcp = MCPManager(registry: registry, onChange: { broadcaster.emit(.mcpServersChanged($0)) })
        self.broadcaster = broadcaster
        self.broker = InteractionBroker(emit: { broadcaster.emit($0) })
        self.factory = factory
    }

    /// Hooks up observers, applies the loaded configuration and connects
    /// the MCP servers (in the background: `start` doesn't wait for them).
    func start() async {
        await registry.onChange { [broadcaster] in broadcaster.emit(.toolsChanged) }
        await applyToolPolicies()
        await mcp.apply(mcpConfig)
        refreshDiscoveredModels()
        startWatching()
    }

    /// Disconnects MCP servers and stops their processes. Call on quit.
    public func shutdown() async {
        watcher?.cancel()
        discovery?.cancel()
        for task in running.values { task.cancel() }
        await mcp.shutdown()
    }

    public nonisolated func events() -> AsyncStream<EngineEvent> {
        broadcaster.subscribe()
    }

    // MARK: Configuration

    /// Every model the user can pick: the ones declared in `config.json`,
    /// plus the ones served by providers with `discoverModels: true`.
    public var models: [ModelRef] {
        var models = config.declaredModels
        for (provider, ids) in discovered.sorted(by: { $0.key < $1.key }) {
            for id in ids where !models.contains(ModelRef(provider: provider, model: id)) {
                models.append(ModelRef(provider: provider, model: id))
            }
        }
        return models
    }

    public func reloadConfig() async {
        let loader = ConfigLoader(home: home)
        do {
            config = try loader.loadConfig()
            mcpConfig = try loader.loadMCP()
            providers.removeAll()
            await applyToolPolicies()
            await mcp.apply(mcpConfig)
            refreshDiscoveredModels()
            broadcaster.emit(.configReloaded)
        } catch {
            broadcaster.emit(.configFailed(error.localizedDescription))
        }
    }

    /// `config.json` rules win over `mcp.json` ones on the same name.
    private func applyToolPolicies() async {
        await registry.setPolicies(mcpConfig.toolPolicies.merging(config.tools ?? [:]) { _, global in global })
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

    // MARK: Models

    /// Asks a provider which models it serves, for the registration UI.
    public func availableModels(provider name: String) async throws -> [String] {
        guard let providerConfig = config.providers[name] else { throw KuriError.unknownProvider(name) }
        return try await factory.discoverModels(name: name, config: providerConfig)
    }

    /// Adds (or replaces) a model in `config.json`.
    public func register(_ model: ModelConfig, provider: String) async throws {
        try ConfigEditor(home: home).register(model, provider: provider)
        await reloadConfig()
    }

    public func unregister(model id: String, provider: String) async throws {
        try ConfigEditor(home: home).unregister(model: id, provider: provider)
        await reloadConfig()
    }

    public func setDefaultModel(_ ref: ModelRef?) async throws {
        try ConfigEditor(home: home).setDefaultModel(ref)
        await reloadConfig()
    }

    private func refreshDiscoveredModels() {
        discovery?.cancel()
        let targets = config.providers.filter { $0.value.discoverModels == true }
        let factory = factory
        discovery = Task { [weak self] in
            var found: [String: [String]] = [:]
            for (name, providerConfig) in targets {
                // A provider that's offline just contributes nothing.
                found[name] = try? await factory.discoverModels(name: name, config: providerConfig)
            }
            guard !Task.isCancelled else { return }
            await self?.setDiscovered(found)
        }
    }

    private func setDiscovered(_ found: [String: [String]]) {
        guard found != discovered else { return }
        discovered = found
        broadcaster.emit(.configReloaded)
    }

    // MARK: Tools

    /// Every tool, built-in and discovered, with its effective policy.
    public func toolCatalog() async -> [ToolInfo] {
        await registry.catalog()
    }

    public func mcpServers() async -> [MCPServerStatus] {
        await mcp.statuses
    }

    public func reconnectMCPServer(_ name: String) async {
        await mcp.reconnect(name)
    }

    // MARK: Memory

    public func memories() async throws -> [Memory] {
        try await store.memories()
    }

    /// Changes made by the user from the UI. Same rules as the tool, except
    /// the size budget: the user decides what's worth keeping.
    public func changeMemories(_ changes: [MemoryChange]) async throws {
        try await store.applyMemoryChanges(changes, source: .user)
        broadcaster.emit(.memoriesChanged)
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
        let toolNames = Set(await registry.specs().map(\.name))
        let runner = TurnRunner(
            conversationID: conversationID,
            turn: turn,
            provider: provider,
            modelConfig: ModelConfigSnapshot(maxOutputTokens: modelConfig?.maxOutputTokens,
                                             reasoningEffort: modelConfig?.reasoningEffort),
            instructions: Instructions.build(conversation: conversation, folders: folders,
                                             memories: try await store.memories(), tools: toolNames),
            folders: folders,
            registry: registry,
            store: store,
            interaction: broker,
            limits: limits,
            emit: { [broadcaster] event in
                broadcaster.emit(event)
                if case .toolFinished(_, let call, let output) = event, call.name == MemoryTool().spec.name,
                   !output.isError {
                    broadcaster.emit(.memoriesChanged)
                }
            })

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
