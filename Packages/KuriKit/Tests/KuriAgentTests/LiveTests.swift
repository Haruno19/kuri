import Foundation
import KuriConfig
import KuriCore
import KuriMCP
import KuriStore
import Testing
@testable import KuriAgent

/// Turns against a real model. Opt-in:
///
///     KURI_LIVE_MODEL=ollama/qwen3.5:2b swift test --filter LiveTests
///
/// `KURI_LIVE_BASE_URL` defaults to Ollama's (`http://localhost:11434/v1`).
/// Small models are not deterministic: these check that the plumbing works
/// with a real server, and print each transcript for a human to read.
enum Live {
    static let environment = ProcessInfo.processInfo.environment
    static let model = environment["KURI_LIVE_MODEL"].flatMap(ModelRef.init)
    static let baseURL = URL(string: environment["KURI_LIVE_BASE_URL"] ?? "http://localhost:11434/v1")!
}

@Suite(.serialized, .enabled(if: Live.model != nil, "set KURI_LIVE_MODEL to run"))
struct LiveTests {
    struct Run {
        var outcome: TurnOutcome?
        var items: [Item]
        var store: Store

        var toolNames: [String] {
            items.compactMap { if case .toolCall(let call) = $0.payload { call.name } else { nil } }
        }

        var reply: String {
            items.last.flatMap { if case .message(let m) = $0.payload, m.role == .assistant { m.text } else { nil } } ?? ""
        }
    }

    private func makeEngine(mcp: MCPConfig = MCPConfig(), contextWindow: Int? = nil, root: URL? = nil) throws -> (Engine, KuriHome) {
        let model = try #require(Live.model)
        let home = KuriHome(root: root ?? FileManager.default.temporaryDirectory.appending(path: "kuri-live-\(UUID().uuidString)"))
        try home.prepare()
        let config = Config(
            defaultModel: model,
            providers: [model.provider: ProviderConfig(format: .openResponses, baseURL: Live.baseURL,
                                                       models: [ModelConfig(id: model.model, contextWindow: contextWindow)])])
        let engine = Engine(home: home, store: try Store(url: home.database), config: config, mcpConfig: mcp)
        return (engine, home)
    }

    /// Sends `prompt` and drives the turn to the end, answering clarify
    /// questions with `answer` and approving every tool call.
    private func run(_ prompt: String, engine: Engine, in conversation: Conversation? = nil,
                     answer: String = "Kyoto") async throws -> Run {
        let events = engine.events()
        let conversation = if let conversation { conversation } else { try await engine.newConversation() }
        try await engine.send(prompt, to: conversation.id)

        var outcome: TurnOutcome?
        for await event in events {
            switch event {
            case .inputRequested(let request):
                switch request.kind {
                case .clarify(let clarify):
                    let answers = Dictionary(uniqueKeysWithValues: clarify.questions.map { ($0.id, answer) })
                    await engine.respond(to: request.id, with: .answers(answers))
                case .approval:
                    await engine.respond(to: request.id, with: .approved(true))
                }
            case .turnFinished(let id, _, let finished) where id == conversation.id:
                outcome = finished
            default:
                break
            }
            if outcome != nil { break }
        }
        let items = try await engine.store.items(of: conversation.id)
        print("\n── \(prompt)\n" + items.map(Self.describe).joined(separator: "\n") + "\n── \(String(describing: outcome))")
        return Run(outcome: outcome, items: items, store: engine.store)
    }

    private static func describe(_ item: Item) -> String {
        switch item.payload {
        case .message(let m): "\(m.role.rawValue): \(m.text)"
        case .reasoning(let r): "thinking: \(r.text.prefix(200))"
        case .toolCall(let c): "→ \(c.name) \(c.arguments)"
        case .toolResult(let r): "← \(r.isError ? "error: " : "")\(r.output.prefix(300))"
        case .compaction(let c): "summary: \(c.summary)"
        }
    }

    @Test func plainReply() async throws {
        let (engine, home) = try makeEngine()
        defer { try? FileManager.default.removeItem(at: home.root) }
        let run = try await run("Say hello in exactly five words.", engine: engine)
        #expect(run.outcome == .completed(.endTurn))
        #expect(!run.reply.isEmpty)
    }

    @Test func remembersAFact() async throws {
        let (engine, home) = try makeEngine()
        defer { try? FileManager.default.removeItem(at: home.root) }
        let run = try await run("Please remember for the future that my favourite editor is Helix.", engine: engine)
        #expect(run.toolNames.contains("memory"))
        #expect(try await run.store.memories().contains { $0.content.localizedCaseInsensitiveContains("helix") })
    }

    @Test func keepsAPlan() async throws {
        let (engine, home) = try makeEngine()
        defer { try? FileManager.default.removeItem(at: home.root) }
        let run = try await run(
            "I want to bake bread. Use the tasklist tool to write a plan of three steps, then tell me the first one.",
            engine: engine)
        #expect(run.toolNames.contains("tasklist"))
        #expect(run.outcome == .completed(.endTurn))
    }

    @Test func asksBeforeGuessing() async throws {
        let (engine, home) = try makeEngine()
        defer { try? FileManager.default.removeItem(at: home.root) }
        let run = try await run(
            "Help me plan a weekend trip. Before anything else, use the clarify tool to ask me which city.",
            engine: engine, answer: "Kyoto")
        #expect(run.toolNames.contains("clarify"))
        #expect(run.reply.localizedCaseInsensitiveContains("kyoto"))
    }

    @Test func searchesPastConversations() async throws {
        let (engine, home) = try makeEngine()
        defer { try? FileManager.default.removeItem(at: home.root) }
        let past = try await engine.newConversation()
        var titled = past
        titled.title = "Lisbon trip"
        try await engine.update(titled)
        for (role, text) in [(Role.user, "Which neighbourhood should I stay in, in Lisbon?"),
                             (.assistant, "Stay in Alfama: it's walkable and close to the miradouros.")] {
            try await engine.store.append(Item(conversationID: past.id, payload: .message(Message(role: role, text: text))))
        }
        let run = try await run(
            "Which Lisbon neighbourhood did you recommend to me in an earlier conversation? Use conversation_search.",
            engine: engine)
        #expect(run.toolNames.contains("conversation_search"))
        #expect(run.reply.localizedCaseInsensitiveContains("alfama"))
    }

    @Test func usesAnMCPTool() async throws {
        let fixture = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "KuriMCPTests/Fixtures/stdio_server.py")
        let (engine, home) = try makeEngine(mcp: MCPConfig(mcpServers: [
            "calc": MCPServerConfig(command: "/usr/bin/python3", args: [fixture.path]),
        ]))
        defer { try? FileManager.default.removeItem(at: home.root) }
        await engine.start()
        defer { Task { await engine.shutdown() } }
        for _ in 0..<200 {
            if await engine.toolCatalog().contains(where: { $0.name == "calc__add" }) { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        let run = try await run("Use the calc add tool to compute 1234 + 4321, then tell me the result.", engine: engine)
        #expect(run.toolNames.contains("calc__add"))
        #expect(run.reply.contains("5555") || run.reply.contains("5,555"))
    }

    @Test func discoversAndRegistersModels() async throws {
        let model = try #require(Live.model)
        let root = FileManager.default.temporaryDirectory.appending(path: "kuri-live-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let home = KuriHome(root: root)
        try home.prepare()
        try Data("""
            { providers: { \(model.provider): { format: "open-responses", baseURL: "\(Live.baseURL.absoluteString)", discoverModels: true } } }
            """.utf8).write(to: home.configFile)
        let engine = try await Engine.open(home: home)
        defer { Task { await engine.shutdown() } }

        let available = try await engine.availableModels(provider: model.provider)
        print("\n── \(model.provider) serves: \(available.joined(separator: ", "))")
        #expect(available.contains(model.model))

        // discoverModels makes them pickable without registering.
        for _ in 0..<100 {
            if await engine.models.contains(model) { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(await engine.models.contains(model))

        try await engine.register(ModelConfig(id: model.model, contextWindow: 32768), provider: model.provider)
        try await engine.setDefaultModel(model)
        let config = await engine.config
        #expect(config.defaultModel == model)
        #expect(config.modelConfig(for: model)?.contextWindow == 32768)
        print(try String(contentsOf: home.configFile, encoding: .utf8))
    }

    @Test func compactsAndStillRemembers() async throws {
        let (engine, home) = try makeEngine(contextWindow: 2_500)
        defer { try? FileManager.default.removeItem(at: home.root) }
        let conversation = try await engine.newConversation()
        let filler = String(repeating: "We talked at length about the weather, the trains and the price of rice. ", count: 25)
        let seeded: [(Role, String)] = [
            (.user, "Hi! My cat is called Miso. " + filler), (.assistant, "Nice to meet Miso. " + filler),
            (.user, "Let's plan my week. " + filler), (.assistant, "Sure. " + filler),
        ]
        for (role, text) in seeded {
            try await engine.store.append(Item(conversationID: conversation.id, payload: .message(Message(role: role, text: text))))
        }
        let run = try await run("What's my cat's name? Answer in one word.", engine: engine, in: conversation)
        let compactions = run.items.compactMap { if case .compaction(let c) = $0.payload { c } else { nil } }
        print("── summary: \(compactions.first?.summary ?? "none")")
        #expect(compactions.count == 1)
        #expect(run.reply.localizedCaseInsensitiveContains("miso"))
    }

    @Test func resumesAQuestionAfterARelaunch() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "kuri-live-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        // First launch: the model asks, and Kuri "quits" before the answer.
        let (first, home) = try makeEngine(root: root)
        let firstEvents = first.events()
        let conversation = try await first.newConversation()
        try await first.send("Help me plan a weekend trip. Before anything else, use the clarify tool to ask me which city.",
                             to: conversation.id)
        for await event in firstEvents {
            if case .inputRequested = event { break }
            if case .turnFinished = event { Issue.record("the model didn't ask"); return }
        }
        #expect(try await first.store.turns(of: conversation.id).last?.status == .awaitingInput)

        // Second launch on the same database: the question comes back.
        let (second, _) = try makeEngine(root: home.root)
        let events = second.events()
        await second.resumePendingTurns()
        var asked = false
        var outcome: TurnOutcome?
        for await event in events {
            if case .inputRequested(let request) = event, case .clarify(let clarify) = request.kind {
                asked = true
                await second.respond(to: request.id, with: .answers(Dictionary(uniqueKeysWithValues: clarify.questions.map { ($0.id, "Kyoto") })))
            }
            if case .turnFinished(_, _, let finished) = event { outcome = finished; break }
        }
        #expect(asked)
        // A small model may keep asking after that; what matters is that the
        // question came back and the turn went on to finish.
        if case .completed = outcome {} else { Issue.record("turn ended with \(String(describing: outcome))") }
        let items = try await second.store.items(of: conversation.id)
        print("\n── after relaunch\n" + items.map(Self.describe).joined(separator: "\n"))
    }

    @Test func titlesAConversation() async throws {
        let (engine, home) = try makeEngine()
        defer { try? FileManager.default.removeItem(at: home.root) }
        let events = engine.events()
        let conversation = try await engine.newConversation()
        let question = "what does kuri mean in japanese and how is it written? also any recipes?"
        try await engine.send(question, to: conversation.id)
        var title: String?
        let deadline = Task { try await Task.sleep(for: .seconds(90)) }
        for await event in events {
            if case .conversationUpdated(let updated) = event, updated.id == conversation.id,
               updated.title != Engine.provisionalTitle(for: question), !updated.title.isEmpty {
                title = updated.title
                break
            }
            if case .turnFinished = event {
                // The title comes in the background, shortly after.
                Task { try? await Task.sleep(for: .seconds(60)); deadline.cancel() }
            }
            if deadline.isCancelled { break }
        }
        print("\n── generated title: \(title ?? "none")")
        #expect(title != nil)
    }
}

