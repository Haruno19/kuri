import Foundation
import KuriCore
import KuriInference
import KuriStore
import KuriTools
import Synchronization
import Testing
@testable import KuriAgent

private final class Log: Sendable {
    private let entries = Mutex<[String]>([])
    func append(_ entry: String) { entries.withLock { $0.append(entry) } }
    var all: [String] { entries.withLock { $0 } }
}

/// Sleeps, then reports when it ran. Read-only or not, as configured.
private struct SlowTool: Tool {
    let spec: ToolSpec
    let isReadOnly: Bool
    let log: Log

    init(_ name: String, readOnly: Bool, log: Log) {
        spec = ToolSpec(name: name, description: "", parameters: ["type": "object"])
        isReadOnly = readOnly
        self.log = log
    }

    func run(arguments: Data, context: ToolContext) async throws -> ToolOutput {
        log.append("start \(spec.name)")
        try await Task.sleep(for: .milliseconds(300))
        log.append("end \(spec.name)")
        return ToolOutput("\(spec.name) done")
    }
}

@Suite struct ParallelToolTests {
    private func run(_ tools: [SlowTool], calls: [String]) async throws -> (Duration, [String], [String]) {
        let store = try Store(url: nil)
        let conversation = Conversation(model: ModelRef(provider: "test", model: "m"))
        try await store.createConversation(conversation)
        try await store.append(Item(conversationID: conversation.id, payload: .message(Message(role: .user, text: "Go"))))
        let turn = try await store.beginTurn(conversationID: conversation.id, model: ModelRef(provider: "test", model: "m"))
        let provider = ScriptedProvider([
            calls.enumerated().map { .itemCompleted(.toolCall(ToolCall(id: "c\($0.offset)", name: $0.element, arguments: "{}"))) }
                + [.finished(.toolUse)],
            [.itemCompleted(.message(Message(role: .assistant, text: "ok"))), .finished(.endTurn)],
        ])
        let runner = TurnRunner(
            conversationID: conversation.id, turn: turn, provider: provider, modelConfig: ModelConfigSnapshot(),
            instructions: "test", folders: [], registry: ToolRegistry(tools), store: store, interaction: Answering(),
            limits: TurnLimits(), compactor: nil, emit: { _ in })
        let started = ContinuousClock.now
        _ = await runner.run()
        let elapsed = ContinuousClock.now - started
        let results = try await store.items(of: conversation.id).compactMap {
            if case .toolResult(let r) = $0.payload { r.output } else { nil }
        }
        return (elapsed, results, [])
    }

    @Test func readOnlyCallsRunTogetherAndKeepTheirOrder() async throws {
        let log = Log()
        let tools = [SlowTool("a", readOnly: true, log: log), SlowTool("b", readOnly: true, log: log),
                     SlowTool("c", readOnly: true, log: log)]
        let (elapsed, results, _) = try await run(tools, calls: ["a", "b", "c"])
        #expect(elapsed < .milliseconds(800))  // three 300 ms calls, concurrently
        #expect(results == ["a done", "b done", "c done"])
        let events = log.all
        #expect(events.prefix(3).allSatisfy { $0.hasPrefix("start") })
    }

    @Test func writingCallsStayInOrderAndSplitTheBatches() async throws {
        let log = Log()
        let tools = [SlowTool("read1", readOnly: true, log: log), SlowTool("write", readOnly: false, log: log),
                     SlowTool("read2", readOnly: true, log: log)]
        let (_, results, _) = try await run(tools, calls: ["read1", "write", "read2"])
        #expect(results == ["read1 done", "write done", "read2 done"])
        #expect(log.all == ["start read1", "end read1", "start write", "end write", "start read2", "end read2"])
    }
}
