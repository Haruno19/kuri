import Foundation
import KuriConfig
import KuriCore
import KuriInference
import KuriMCP
import KuriSandbox
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
    public nonisolated let sandbox: Sandbox
    private let broker: InteractionBroker
    private let broadcaster: EventBroadcaster
    private let factory: ProviderFactory
    private var providers: [String: any InferenceProvider] = [:]
    /// Models listed by providers that have `discoverModels: true`.
    private var discovered: [String: [String]] = [:]
    private var discovery: Task<Void, Never>?
    private var running: [UUID: Task<Void, Never>] = [:]
    /// Title requests in flight, by conversation, so shutdown can stop them.
    private var titling: [UUID: Task<Void, Never>] = [:]
    /// Messages sent while their conversation was busy, oldest first.
    private var queues: [UUID: [QueuedMessage]] = [:]
    /// The user's task list edits waiting for a running turn's next step.
    private var pendingTaskLists: [UUID: [TaskListTool.Entry]] = [:]
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
        let sandbox = Sandbox(home: home, settings: SandboxSettings(config.sandbox), onStatus: { status in
            broadcaster.emit(.sandboxChanged(status))
        }, onContainer: { conversationID, running in
            broadcaster.emit(.sandboxContainer(conversationID: conversationID, running: running))
        })
        self.sandbox = sandbox
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
        await syncShellTool(sandbox.refreshStatus())
        startWatching()
    }

    /// Disconnects MCP servers and stops their processes. Call on quit.
    public func shutdown() async {
        watcher?.cancel()
        discovery?.cancel()
        for task in running.values { task.cancel() }
        for task in titling.values { task.cancel() }
        await mcp.shutdown()
        await sandbox.stopAll()
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
            await sandbox.update(SandboxSettings(config.sandbox))
            await syncShellTool(sandbox.status)
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

    // MARK: Sandbox and folders

    /// Downloads what the sandbox needs (kernel, init image, container
    /// image), then offers the `shell` tool. Progress arrives as
    /// `.sandboxChanged` events.
    public func setUpSandbox() async throws {
        do {
            try await sandbox.install()
        } catch {
            await syncShellTool(sandbox.status)
            throw error
        }
        await syncShellTool(sandbox.status)
    }

    /// The model gets a shell only once the sandbox is ready.
    private func syncShellTool(_ status: SandboxStatus) async {
        if status == .ready {
            if await registry.tool(named: ShellTool.name) == nil {
                await registry.register(ShellTool(sandbox: sandbox, scratch: { [home] in home.scratchFolder(for: $0) }),
                                        source: .builtIn)
            }
        } else if await registry.tool(named: ShellTool.name) != nil {
            await registry.removeAll(named: ShellTool.name)
        }
    }

    public func folders(of conversationID: UUID) async throws -> [ConversationFolder] {
        try await store.folders(of: conversationID)
    }

    /// Changes the folders the model works in. The conversation's container
    /// restarts with the new mounts on its next command.
    public func setFolders(_ folders: [ConversationFolder], for conversationID: UUID) async throws {
        try await store.setFolders(folders, of: conversationID)
        await sandbox.stop(conversationID)
        broadcaster.emit(.foldersChanged(conversationID: conversationID, folders))
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

    /// The user's title wins: a title still being generated is dropped.
    /// Renaming isn't activity, so `updatedAt` (and the order) stays.
    public func rename(_ conversationID: UUID, to title: String) async throws {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, var conversation = try await store.conversation(conversationID),
              conversation.title != title else { return }
        titling[conversationID]?.cancel()
        titling[conversationID] = nil
        conversation.title = title
        try await store.updateConversation(conversation)
        broadcaster.emit(.conversationUpdated(conversation))
    }

    public func delete(_ conversationID: UUID) async throws {
        cancel(conversationID)
        await sandbox.stop(conversationID)
        try? FileManager.default.removeItem(at: home.scratchFolder(for: conversationID))
        try await store.deleteConversation(conversationID)
        broadcaster.emit(.conversationDeleted(conversationID))
    }

    // MARK: Turns

    /// Adds the user's message and starts a turn. Returns once the turn is
    /// running; follow it through `events()`. While the conversation is
    /// busy, the message is queued instead: it joins the running turn at
    /// its next step, or starts the next turn.
    public func send(_ text: String, to conversationID: UUID) async throws {
        if running[conversationID] != nil {
            queues[conversationID, default: []].append(QueuedMessage(text: text))
            broadcaster.emit(.queueChanged(conversationID: conversationID, queues[conversationID] ?? []))
            return
        }
        try await startTurn(with: [text], in: conversationID)
    }

    /// Removes a queued message before it's delivered.
    public func unqueue(_ messageID: UUID, in conversationID: UUID) {
        guard let index = queues[conversationID]?.firstIndex(where: { $0.id == messageID }) else { return }
        queues[conversationID]?.remove(at: index)
        broadcaster.emit(.queueChanged(conversationID: conversationID, queues[conversationID] ?? []))
    }

    // MARK: Task list

    /// Replaces the conversation's task list with the user's version. It's
    /// stored like the model's own `tasklist` calls, so the current list is
    /// still read from the items and the model sees the change; during a
    /// turn it waits for the next step, where it can't split a call from
    /// its result.
    public func editTaskList(_ entries: [TaskListTool.Entry], in conversationID: UUID) async throws {
        if running[conversationID] != nil {
            pendingTaskLists[conversationID] = entries
            return
        }
        let (call, result) = TaskListTool.userEdit(entries)
        for payload in [Item.Payload.toolCall(call), .toolResult(result)] {
            let item = Item(conversationID: conversationID, payload: payload)
            try await store.append(item)
            broadcaster.emit(.itemAdded(item))
        }
    }

    private func takeTaskList(_ conversationID: UUID) -> [TaskListTool.Entry]? {
        pendingTaskLists.removeValue(forKey: conversationID)
    }

    /// Hands the queue to the running turn and empties it.
    private func takeQueued(_ conversationID: UUID) -> [String] {
        guard let queue = queues.removeValue(forKey: conversationID), !queue.isEmpty else { return [] }
        broadcaster.emit(.queueChanged(conversationID: conversationID, []))
        return queue.map(\.text)
    }

    private func startTurn(with texts: [String], in conversationID: UUID) async throws {
        var (conversation, model, provider) = try await prepareTurn(in: conversationID)
        for text in texts {
            let message = Item(conversationID: conversationID, payload: .message(Message(role: .user, text: text)))
            try await store.append(message)
            broadcaster.emit(.itemAdded(message))
        }
        let text = texts[0]

        if conversation.title.isEmpty {
            // Provisional: replaced by a generated title after the first completed turn.
            conversation.title = Self.provisionalTitle(for: text)
        }
        conversation.model = model
        try await update(conversation)

        let turn = try await store.beginTurn(conversationID: conversationID, model: model)
        broadcaster.emit(.turnStarted(turn))
        try await startRunner(for: turn, in: conversation, provider: provider, resuming: false)
    }

    /// Starts a turn without a new message, so the model picks up where a
    /// failed, stopped or interrupted turn left off.
    public func continueConversation(_ conversationID: UUID) async throws {
        let (conversation, model, provider) = try await prepareTurn(in: conversationID)
        let turn = try await store.beginTurn(conversationID: conversationID, model: model)
        broadcaster.emit(.turnStarted(turn))
        try await startRunner(for: turn, in: conversation, provider: provider, resuming: false)
    }

    /// Answers the last user message again: everything after it (the
    /// previous answer, its tool calls, any summary made meanwhile) is
    /// removed, and a new turn starts from that message.
    public func retry(_ conversationID: UUID) async throws {
        let items = try await store.items(of: conversationID)
        guard let message = items.last(where: { item in
            if case .message(let message) = item.payload { message.role == .user } else { false }
        }) else { return }
        let (conversation, model, provider) = try await prepareTurn(in: conversationID)
        let removed = try await store.removeItems(after: message.id, in: conversationID)
        if !removed.isEmpty { broadcaster.emit(.itemsRemoved(conversationID: conversationID, removed)) }
        let turn = try await store.beginTurn(conversationID: conversationID, model: model)
        broadcaster.emit(.turnStarted(turn))
        try await startRunner(for: turn, in: conversation, provider: provider, resuming: false)
    }

    /// Picks up turns that were waiting for the user when Kuri quit: their
    /// questions and approvals are asked again. Call once subscribed to
    /// `events()`, so the requests aren't missed.
    public func resumePendingTurns() async {
        guard let pending = try? await store.turns(withStatus: .awaitingInput) else { return }
        for turn in pending where running[turn.conversationID] == nil {
            do {
                guard let conversation = try await store.conversation(turn.conversationID) else { continue }
                let provider = try provider(for: turn.model)
                broadcaster.emit(.turnStarted(turn))
                try await startRunner(for: turn, in: conversation, provider: provider, resuming: true)
            } catch {
                let message = "Couldn't resume: \(error.localizedDescription)"
                try? await store.finishTurn(turn.id, status: .failed, stopReason: nil, usage: turn.usage, error: message)
                broadcaster.emit(.turnFinished(conversationID: turn.conversationID, turnID: turn.id, .failed(message)))
            }
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

    public var runningConversations: Set<UUID> { Set(running.keys) }

    private func prepareTurn(in conversationID: UUID) async throws -> (Conversation, ModelRef, any InferenceProvider) {
        guard running[conversationID] == nil else {
            throw KuriError.provider("This conversation is already running.")
        }
        guard let conversation = try await store.conversation(conversationID) else {
            throw KuriError.database("No conversation with id \(conversationID).")
        }
        guard let model = conversation.model ?? config.defaultModel else {
            throw KuriError.invalidConfig(file: "config.json", reason: "no model selected and no defaultModel set")
        }
        return (conversation, model, try provider(for: model))
    }

    private func startRunner(for turn: Turn, in conversation: Conversation, provider: any InferenceProvider,
                             resuming: Bool) async throws {
        let folders = try await store.folders(of: conversation.id)
        let mounts = SandboxMounts.plan(folders: folders, scratch: home.scratchFolder(for: conversation.id))
        let memories = try await store.memories()
        func choice(_ model: ModelRef, _ provider: any InferenceProvider) async -> ModelChoice {
            let modelConfig = config.modelConfig(for: model)
            let toolNames = provider.supportsTools ? Set(await registry.specs().map(\.name)) : []
            return ModelChoice(
                model: model, provider: provider,
                modelConfig: ModelConfigSnapshot(maxOutputTokens: modelConfig?.maxOutputTokens,
                                                 reasoningEffort: modelConfig?.reasoningEffort,
                                                 contextWindow: config.contextWindow(for: model)),
                instructions: Instructions.build(conversation: conversation, folders: folders, mounts: mounts,
                                                 image: SandboxSettings(config.sandbox).image,
                                                 memories: memories, tools: toolNames),
                useTools: provider.supportsTools)
        }
        let primary = await choice(turn.model, provider)
        var fallbacks: [ModelChoice] = []
        for ref in config.modelConfig(for: turn.model)?.fallbacks ?? [] where ref != turn.model {
            // A fallback whose provider isn't configured can't help; skip it.
            guard let fallbackProvider = try? self.provider(for: ref) else { continue }
            fallbacks.append(await choice(ref, fallbackProvider))
        }
        var limits = limits
        limits.compactionThreshold = config.compactionThreshold
        let runner = TurnRunner(
            conversationID: conversation.id,
            turn: turn,
            provider: provider,
            modelConfig: primary.modelConfig,
            instructions: primary.instructions,
            folders: folders,
            registry: registry,
            store: store,
            interaction: broker,
            limits: limits,
            compactor: compactor(for: turn.model, fallback: provider),
            takeQueued: { [weak self] in await self?.takeQueued(conversation.id) ?? [] },
            takeTaskList: { [weak self] in await self?.takeTaskList(conversation.id) },
            useTools: primary.useTools,
            fallbacks: fallbacks,
            emit: { [broadcaster] event in
                broadcaster.emit(event)
                if case .toolFinished(_, let call, let output) = event, call.name == MemoryTool().spec.name,
                   !output.isError {
                    broadcaster.emit(.memoriesChanged)
                }
            })

        let conversationID = conversation.id
        running[conversationID] = Task { [weak self] in
            let outcome = await runner.run(resuming: resuming)
            if case .completed = outcome { await self?.generateTitleIfNeeded(conversationID) }
            await self?.turnEnded(conversationID)
        }
    }

    /// Clears the running state, then starts a turn for anything queued
    /// too late to join (or queued before Stop: probably a redirection).
    private func turnEnded(_ conversationID: UUID) async {
        running[conversationID] = nil
        // An edit made after the turn's last step.
        if let entries = takeTaskList(conversationID) {
            try? await editTaskList(entries, in: conversationID)
        }
        let queued = takeQueued(conversationID)
        guard !queued.isEmpty else { return }
        do {
            try await startTurn(with: queued, in: conversationID)
        } catch {
            broadcaster.emit(.configFailed(error.localizedDescription))
        }
    }

    // MARK: Titles

    public func setGenerateTitles(_ enabled: Bool) async throws {
        try ConfigEditor(home: home).setGenerateTitles(enabled)
        await reloadConfig()
    }

    public func setStartInBackground(_ enabled: Bool) async throws {
        try ConfigEditor(home: home).setStartInBackground(enabled)
        await reloadConfig()
    }

    public func setCompactAt(_ percent: Int) async throws {
        try ConfigEditor(home: home).setCompactAt(percent)
        await reloadConfig()
    }

    public func setAppearance(_ appearance: Appearance) async throws {
        try ConfigEditor(home: home).setAppearance(appearance)
        await reloadConfig()
    }

    /// `nil` values fall back to their defaults. Changing the image, CPUs
    /// or memory stops running containers when the config reloads.
    public func setSandbox(image: String?, cpus: Int?, memoryMiB: Int?, idleMinutes: Int?) async throws {
        try ConfigEditor(home: home).setSandbox(image: image, cpus: cpus, memoryMiB: memoryMiB, idleMinutes: idleMinutes)
        await reloadConfig()
    }

    /// After the first completed turn, replaces the provisional title (the
    /// first line of the first message) with a generated one. In the
    /// background; a failure just leaves the provisional title.
    private func generateTitleIfNeeded(_ conversationID: UUID) async {
        guard config.generateTitles != false,
              let conversation = try? await store.conversation(conversationID),
              let model = conversation.model ?? config.defaultModel,
              let completed = try? await store.turns(of: conversationID).filter({ $0.status == .completed }),
              completed.count == 1,
              let items = try? await store.items(of: conversationID)
        else { return }
        let messages = items.compactMap { item -> Message? in if case .message(let m) = item.payload { m } else { nil } }
        guard let question = messages.first(where: { $0.role == .user })?.text,
              let answer = messages.first(where: { $0.role == .assistant })?.text,
              conversation.title == Self.provisionalTitle(for: question)
        else { return }

        let target = config.utilityModel ?? model
        guard let provider = try? provider(for: target) else { return }
        let generator = TitleGenerator(provider: provider, model: target.model)
        titling[conversationID] = Task { [weak self] in
            let title = try? await generator.title(question: question, answer: answer)
            await self?.titled(conversationID, title: title, ifStill: conversation.title)
        }
    }

    private func titled(_ conversationID: UUID, title: String?, ifStill provisional: String) async {
        titling[conversationID] = nil
        guard let title, !Task.isCancelled else { return }
        // The user may have renamed it meanwhile.
        guard var conversation = try? await store.conversation(conversationID), conversation.title == provisional else { return }
        conversation.title = title
        try? await update(conversation)
    }

    // MARK: Compaction

    /// Summarizes the conversation up to its latest exchange, which stays
    /// verbatim. Returns when done.
    public func compact(_ conversationID: UUID) async throws {
        guard running[conversationID] == nil else {
            throw KuriError.provider("This conversation is running.")
        }
        guard let conversation = try await store.conversation(conversationID),
              let model = conversation.model ?? config.defaultModel
        else { throw KuriError.invalidConfig(file: "config.json", reason: "no model selected and no defaultModel set") }
        let compactor = compactor(for: model, fallback: try provider(for: model))
        let items = try await store.items(of: conversationID)
        guard let cut = Compactor.cut(in: items, budget: .max) else {
            throw KuriError.provider("Nothing to summarize yet: the conversation is a single exchange.")
        }

        broadcaster.emit(.compacting(conversationID: conversationID, true))
        let task = Task { try await compactor.compact(items, keepingFrom: cut, conversationID: conversationID, turnID: nil) }
        // Registered as running, so the composer waits and Stop cancels it.
        running[conversationID] = Task {
            await withTaskCancellationHandler { _ = try? await task.value } onCancel: { task.cancel() }
        }
        let item: Item
        do {
            item = try await task.value
        } catch {
            broadcaster.emit(.compacting(conversationID: conversationID, false))
            await turnEnded(conversationID)
            throw error
        }
        broadcaster.emit(.itemAdded(item))
        broadcaster.emit(.compacting(conversationID: conversationID, false))
        await turnEnded(conversationID)
    }

    /// Whether the conversation's container is up.
    public func isSandboxRunning(_ conversationID: UUID) async -> Bool {
        await sandbox.isRunning(conversationID)
    }

    /// An estimate of how much of the model's context the conversation
    /// fills, in tokens, and what fills it.
    public func contextUsage(_ conversationID: UUID) async throws -> ContextUsage {
        guard let conversation = try await store.conversation(conversationID) else { return ContextUsage() }
        let items = try await store.items(of: conversationID)
        let model = conversation.model ?? config.defaultModel
        let folders = try await store.folders(of: conversationID)
        let usesTools = model.flatMap { try? provider(for: $0) }?.supportsTools ?? true
        let tools = usesTools ? await registry.specs() : []
        let instructions = Instructions.build(
            conversation: conversation, folders: folders,
            mounts: SandboxMounts.plan(folders: folders, scratch: home.scratchFolder(for: conversationID)),
            image: SandboxSettings(config.sandbox).image,
            memories: try await store.memories(), tools: Set(tools.map(\.name)))
        let history = TurnRunner.history(from: items)
        let request = InferenceRequest(model: model?.model ?? "", instructions: instructions,
                                       items: history, tools: tools)
        let total = ContextEstimate.tokens(request)
        let memory = try await store.memories().reduce(0) { $0 + $1.handle.count + $1.content.count + 3 } / 4
        let toolOutput = ContextEstimate.tokens(history.filter {
            switch $0 {
            case .toolCall, .toolResult: true
            default: false
            }
        })
        let messages = ContextEstimate.tokens(history) - toolOutput
        return ContextUsage(tokens: total, window: model.flatMap { config.contextWindow(for: $0) },
                            system: max(0, total - messages - toolOutput - memory), memory: memory,
                            messages: messages, toolOutput: toolOutput)
    }

    /// Summaries come from the utility model when one is set, otherwise from
    /// the conversation's own model.
    private func compactor(for model: ModelRef, fallback: any InferenceProvider) -> Compactor {
        if let utility = config.utilityModel, let provider = try? provider(for: utility) {
            return Compactor(provider: provider, model: utility.model, store: store)
        }
        return Compactor(provider: fallback, model: model.model, store: store)
    }

    static func provisionalTitle(for text: String) -> String {
        let firstLine = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? text
        let trimmed = firstLine.trimmingCharacters(in: .whitespaces)
        return trimmed.count > 60 ? String(trimmed.prefix(57)) + "…" : trimmed
    }
}
