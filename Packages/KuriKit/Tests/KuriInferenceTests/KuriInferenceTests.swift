import Foundation
import KuriConfig
import KuriCore
import Testing
@testable import KuriInference

@Suite struct SSEParserTests {
    private func parse(_ text: String) -> [SSEEvent] {
        var parser = SSEParser()
        var events = Array(text.utf8).compactMap { parser.feed($0) }
        if let last = parser.finish() { events.append(last) }
        return events
    }

    @Test func parsesEventsSeparatedByBlankLines() {
        let events = parse("event: a\ndata: {\"x\":1}\n\n: keep-alive\n\ndata: line1\ndata: line2\n\n")
        #expect(events == [SSEEvent(event: "a", data: #"{"x":1}"#), SSEEvent(event: nil, data: "line1\nline2")])
    }

    @Test func handlesCRLFAndUnterminatedTail() {
        let events = parse("data: one\r\n\r\ndata: two")
        #expect(events.map(\.data) == ["one", "two"])
    }
}

@Suite struct OpenResponsesTests {
    @Test func decodesATextAndToolCallStream() throws {
        let lines = [
            #"{"type":"response.created","response":{}}"#,
            #"{"type":"response.output_item.added","item":{"type":"reasoning","id":"rs_1"}}"#,
            #"{"type":"response.reasoning_text.delta","item_id":"rs_1","delta":"Hmm"}"#,
            #"{"type":"response.output_item.done","item":{"type":"reasoning","id":"rs_1","content":[{"type":"reasoning_text","text":"Hmm"}]}}"#,
            #"{"type":"response.output_text.delta","item_id":"msg_1","delta":"Let me "}"#,
            #"{"type":"response.output_text.delta","item_id":"msg_1","delta":"check."}"#,
            #"{"type":"response.output_item.done","item":{"type":"message","id":"msg_1","role":"assistant","content":[{"type":"output_text","text":"Let me check."}]}}"#,
            #"{"type":"response.output_item.added","item":{"type":"function_call","id":"fc_1","call_id":"call_9","name":"tasklist","arguments":""}}"#,
            #"{"type":"response.function_call_arguments.delta","item_id":"fc_1","delta":"{\"tasks\":[]}"}"#,
            #"{"type":"response.output_item.done","item":{"type":"function_call","id":"fc_1","call_id":"call_9","name":"tasklist","arguments":"{\"tasks\":[]}"}}"#,
            #"{"type":"response.completed","response":{"usage":{"input_tokens":120,"output_tokens":30,"output_tokens_details":{"reasoning_tokens":5},"input_tokens_details":{"cached_tokens":100}}}}"#,
        ]
        var decoder = OpenResponsesStreamDecoder(provider: "ollama")
        let events = try lines.flatMap { try decoder.decode($0) }

        #expect(events == [
            .reasoningDelta("Hmm"),
            .itemCompleted(.reasoning(Reasoning(text: "Hmm"))),
            .textDelta("Let me "),
            .textDelta("check."),
            .itemCompleted(.message(Message(role: .assistant, text: "Let me check."))),
            .toolCallStarted(callID: "call_9", name: "tasklist"),
            .toolCallArgumentsDelta(callID: "call_9", delta: #"{"tasks":[]}"#),
            .itemCompleted(.toolCall(ToolCall(id: "call_9", name: "tasklist", arguments: #"{"tasks":[]}"#))),
            .usage(Usage(inputTokens: 120, outputTokens: 30, reasoningTokens: 5, cachedInputTokens: 100)),
            .finished(.toolUse),
        ])
    }

    @Test func surfacesErrorsAndTruncation() throws {
        var decoder = OpenResponsesStreamDecoder(provider: "x")
        #expect(throws: KuriError.self) {
            try decoder.decode(#"{"type":"response.failed","response":{"error":{"message":"boom"}}}"#)
        }
        let events = try decoder.decode(#"{"type":"response.incomplete","response":{"incomplete_details":{"reason":"max_output_tokens"}}}"#)
        #expect(events == [.finished(.maxTokens)])
    }

    @Test func encodesStatelessRequests() {
        let request = InferenceRequest(
            model: "qwen3:8b",
            instructions: "Be brief.",
            items: [
                .message(Message(role: .user, text: "Hi")),
                .reasoning(Reasoning(text: "no opaque state")),
                .toolCall(ToolCall(id: "c1", name: "tasklist", arguments: "{}")),
                .toolResult(ToolResult(callID: "c1", output: "ok")),
                .message(Message(role: .assistant, text: "Done.")),
            ],
            tools: [ToolSpec(name: "tasklist", description: "d", parameters: ["type": "object"])])
        let body = OpenResponsesProvider.body(for: request)

        #expect(body["store"] == false)
        #expect(body["stream"] == true)
        guard case .array(let input) = body["input"] else {
            Issue.record("input is not an array")
            return
        }
        #expect(input.map { $0["type"]?.stringValue } == ["message", "function_call", "function_call_output", "message"])
        #expect(input[3]["content"] == [["type": "output_text", "text": "Done."]])
        #expect(body["tools"] == [["type": "function", "name": "tasklist", "description": "d", "parameters": ["type": "object"]]])
    }
}

final class ModelsStub: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var authorization: String?
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "models.test" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.authorization = request.value(forHTTPHeaderField: "Authorization")
        let body = #"{"object":"list","data":[{"id":"qwen3.5:2b"},{"id":"bonsai-2:9b"},{"id":"qwen3.5:2b"}]}"#
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil,
                                                              headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@Suite struct ModelDiscoveryTests {
    @Test func listsModelsFromTheModelsEndpoint() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ModelsStub.self]
        let factory = ProviderFactory(session: URLSession(configuration: configuration))
        let models = try await factory.discoverModels(
            name: "x", config: ProviderConfig(format: .openResponses, baseURL: URL(string: "http://models.test/v1"),
                                             apiKey: .literal("k")))
        #expect(models == ["bonsai-2:9b", "qwen3.5:2b"])
        #expect(ModelsStub.authorization == "Bearer k")
    }

    @Test func saysWhenDiscoveryIsUnsupported() async {
        await #expect(throws: KuriError.self) {
            try await ProviderFactory().discoverModels(name: "a", config: ProviderConfig(format: .anthropicMessages))
        }
    }
}
