import Foundation
import KuriConfig
import KuriCore
import KuriInference
import KuriStore
import Synchronization
import Testing
@testable import KuriAgent

/// Serves scripted Open Responses SSE bodies, one per request, so the
/// engine runs through the real HTTP + SSE + adapter path without a server.
final class StubResponsesProtocol: URLProtocol, @unchecked Sendable {
    static let bodies = Mutex<[String]>([])
    static let requestBodies = Mutex<[Data]>([])

    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "stub.test" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        if let stream = request.httpBodyStream {
            stream.open()
            var data = Data()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }
                data.append(buffer, count: count)
            }
            stream.close()
            Self.requestBodies.withLock { $0.append(data) }
        }
        let body = Self.bodies.withLock { $0.isEmpty ? "" : $0.removeFirst() }
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Type": "text/event-stream"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    static func sse(_ events: [String]) -> String {
        events.map { "data: \($0)\n\n" }.joined()
    }
}

@Suite(.serialized) struct EngineTests {
    @Test func sendRunsATurnThroughTheOpenResponsesAdapter() async throws {
        StubResponsesProtocol.requestBodies.withLock { $0 = [] }
        StubResponsesProtocol.bodies.withLock {
            $0 = [
                StubResponsesProtocol.sse([
                    #"{"type":"response.output_item.added","item":{"type":"function_call","id":"fc","call_id":"call_1","name":"tasklist","arguments":""}}"#,
                    #"{"type":"response.output_item.done","item":{"type":"function_call","id":"fc","call_id":"call_1","name":"tasklist","arguments":"{\"tasks\":[{\"content\":\"Say hi\",\"status\":\"completed\"}]}"}}"#,
                    #"{"type":"response.completed","response":{"usage":{"input_tokens":50,"output_tokens":10}}}"#,
                ]),
                StubResponsesProtocol.sse([
                    #"{"type":"response.output_text.delta","delta":"Hi!"}"#,
                    #"{"type":"response.output_item.done","item":{"type":"message","role":"assistant","content":[{"type":"output_text","text":"Hi!"}]}}"#,
                    #"{"type":"response.completed","response":{"usage":{"input_tokens":70,"output_tokens":2}}}"#,
                ]),
            ]
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubResponsesProtocol.self]
        let session = URLSession(configuration: configuration)

        let root = FileManager.default.temporaryDirectory.appending(path: "kuri-engine-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let home = KuriHome(root: root)
        try home.prepare()

        let config = Config(
            defaultModel: ModelRef("stub/test-model"),
            providers: ["stub": ProviderConfig(format: .openResponses, baseURL: URL(string: "http://stub.test/v1"),
                                               apiKey: .literal("secret"))])
        let engine = Engine(home: home, store: try Store(url: home.database), config: config,
                            mcpConfig: MCPConfig(), factory: ProviderFactory(session: session))

        let events = engine.events()
        let conversation = try await engine.newConversation()
        try await engine.send("Say hi\nplease", to: conversation.id)

        var outcome: TurnOutcome?
        var deltas = ""
        for await event in events {
            if case .inference(_, .textDelta(let delta)) = event { deltas += delta }
            if case .turnFinished(_, _, let finished) = event {
                outcome = finished
                break
            }
        }
        #expect(outcome == .completed(.endTurn))
        #expect(deltas == "Hi!")

        let items = try await engine.store.items(of: conversation.id)
        #expect(items.map(\.payload.kind) == ["message", "toolCall", "toolResult", "message"])
        #expect(try await engine.store.conversation(conversation.id)?.title == "Say hi")
        #expect(try await engine.store.turns(of: conversation.id).first?.usage.inputTokens == 120)

        // The second request was stateless and carried the whole history.
        let second = try #require(StubResponsesProtocol.requestBodies.withLock { $0.last })
        let body = try JSONDecoder().decode(JSONValue.self, from: second)
        #expect(body["store"] == false)
        guard case .array(let input) = body["input"] else {
            Issue.record("no input array")
            return
        }
        #expect(input.map { $0["type"]?.stringValue } == ["message", "function_call", "function_call_output"])
    }

    @Test func runsMCPToolsWithApproval() async throws {
        StubResponsesProtocol.requestBodies.withLock { $0 = [] }
        let fixture = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "KuriMCPTests/Fixtures/stdio_server.py")
        StubResponsesProtocol.bodies.withLock {
            $0 = [
                StubResponsesProtocol.sse([
                    #"{"type":"response.output_item.done","item":{"type":"function_call","id":"fc","call_id":"call_1","name":"fixture__add","arguments":"{\"a\":2,\"b\":40}"}}"#,
                    #"{"type":"response.completed","response":{}}"#,
                ]),
                StubResponsesProtocol.sse([
                    #"{"type":"response.output_item.done","item":{"type":"message","role":"assistant","content":[{"type":"output_text","text":"42"}]}}"#,
                    #"{"type":"response.completed","response":{}}"#,
                ]),
            ]
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubResponsesProtocol.self]

        let root = FileManager.default.temporaryDirectory.appending(path: "kuri-engine-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let home = KuriHome(root: root)
        try home.prepare()
        let engine = Engine(
            home: home, store: try Store(url: home.database),
            config: Config(defaultModel: ModelRef("stub/m"),
                           providers: ["stub": ProviderConfig(format: .openResponses, baseURL: URL(string: "http://stub.test/v1"))]),
            mcpConfig: MCPConfig(mcpServers: ["fixture": MCPServerConfig(command: "/usr/bin/python3", args: [fixture.path])]),
            factory: ProviderFactory(session: URLSession(configuration: configuration)))
        let events = engine.events()
        await engine.start()
        defer { Task { await engine.shutdown() } }

        // Wait for discovery before sending, so the tool is in the request.
        var connected = false
        for _ in 0..<200 where !connected {
            connected = await engine.toolCatalog().contains { $0.name == "fixture__add" }
            if !connected { try await Task.sleep(for: .milliseconds(50)) }
        }
        #expect(connected)

        let conversation = try await engine.newConversation()
        try await engine.send("What is 2 + 40?", to: conversation.id)

        var approvals = 0
        var outcome: TurnOutcome?
        for await event in events {
            if case .inputRequested(let request) = event, case .approval(let approval) = request.kind {
                #expect(approval.tool == "fixture__add")
                approvals += 1
                await engine.respond(to: request.id, with: .approved(true))
            }
            if case .turnFinished(_, _, let finished) = event {
                outcome = finished
                break
            }
        }
        #expect(outcome == .completed(.endTurn))
        #expect(approvals == 1)
        let results = try await engine.store.items(of: conversation.id).compactMap {
            if case .toolResult(let result) = $0.payload { result } else { nil }
        }
        #expect(results.map(\.output) == ["42"])

        // The request listed the MCP tool next to the built-ins.
        let first = try #require(StubResponsesProtocol.requestBodies.withLock { $0.first })
        let body = try JSONDecoder().decode(JSONValue.self, from: first)
        guard case .array(let tools) = body["tools"] else {
            Issue.record("no tools in request")
            return
        }
        #expect(tools.contains { $0["name"] == "fixture__add" })
        #expect(tools.contains { $0["name"] == "memory" })
    }
}
