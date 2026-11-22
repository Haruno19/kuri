import Foundation
import KuriConfig
import KuriCore
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

    private func makeEngine() throws -> (Engine, KuriHome) {
        let model = try #require(Live.model)
        let root = FileManager.default.temporaryDirectory.appending(path: "kuri-live-\(UUID().uuidString)")
        let home = KuriHome(root: root)
        try home.prepare()
        let config = Config(
            defaultModel: model,
            providers: [model.provider: ProviderConfig(format: .openResponses, baseURL: Live.baseURL,
                                                       models: [ModelConfig(id: model.model)])])
        let engine = Engine(home: home, store: try Store(url: home.database), config: config, mcpConfig: MCPConfig())
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
}
