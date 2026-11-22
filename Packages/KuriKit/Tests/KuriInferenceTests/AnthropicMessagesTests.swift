import Foundation
import KuriConfig
import KuriCore
import Synchronization
import Testing
@testable import KuriInference

@Suite struct AnthropicMessagesTests {
    @Test func decodesThinkingTextAndToolUse() throws {
        let lines = [
            #"{"type":"message_start","message":{"usage":{"input_tokens":20,"cache_creation_input_tokens":30,"cache_read_input_tokens":100,"output_tokens":1}}}"#,
            #"{"type":"content_block_start","index":0,"content_block":{"type":"thinking","thinking":""}}"#,
            #"{"type":"content_block_delta","index":0,"delta":{"type":"thinking_delta","thinking":"Hmm"}}"#,
            #"{"type":"content_block_delta","index":0,"delta":{"type":"signature_delta","signature":"sig=="}}"#,
            #"{"type":"content_block_stop","index":0}"#,
            #"{"type":"ping"}"#,
            #"{"type":"content_block_start","index":1,"content_block":{"type":"text","text":""}}"#,
            #"{"type":"content_block_delta","index":1,"delta":{"type":"text_delta","text":"Let me "}}"#,
            #"{"type":"content_block_delta","index":1,"delta":{"type":"text_delta","text":"check."}}"#,
            #"{"type":"content_block_stop","index":1}"#,
            #"{"type":"content_block_start","index":2,"content_block":{"type":"tool_use","id":"toolu_1","name":"tasklist","input":{}}}"#,
            #"{"type":"content_block_delta","index":2,"delta":{"type":"input_json_delta","partial_json":"{\"tasks\":"}}"#,
            #"{"type":"content_block_delta","index":2,"delta":{"type":"input_json_delta","partial_json":"[]}"}}"#,
            #"{"type":"content_block_stop","index":2}"#,
            #"{"type":"message_delta","delta":{"stop_reason":"tool_use"},"usage":{"output_tokens":42}}"#,
            #"{"type":"message_stop"}"#,
        ]
        var decoder = AnthropicStreamDecoder(provider: "anthropic")
        let events = try lines.flatMap { try decoder.decode($0) }

        #expect(events == [
            .reasoningDelta("Hmm"),
            .itemCompleted(.reasoning(Reasoning(text: "Hmm", opaque: "sig==", provider: "anthropic"))),
            .textDelta("Let me "),
            .textDelta("check."),
            .itemCompleted(.message(Message(role: .assistant, text: "Let me check."))),
            .toolCallStarted(callID: "toolu_1", name: "tasklist"),
            .toolCallArgumentsDelta(callID: "toolu_1", delta: #"{"tasks":"#),
            .toolCallArgumentsDelta(callID: "toolu_1", delta: "[]}"),
            .itemCompleted(.toolCall(ToolCall(id: "toolu_1", name: "tasklist", arguments: #"{"tasks":[]}"#))),
            .usage(Usage(inputTokens: 150, outputTokens: 42, cachedInputTokens: 100)),
            .finished(.toolUse),
        ])
    }

    @Test func handlesWholeInputsRedactionUnsignedThinkingAndErrors() throws {
        var decoder = AnthropicStreamDecoder(provider: "a")
        // Input sent up front, no deltas.
        _ = try decoder.decode(#"{"type":"content_block_start","index":0,"content_block":{"type":"tool_use","id":"t","name":"memory","input":{"op":"list"}}}"#)
        #expect(try decoder.decode(#"{"type":"content_block_stop","index":0}"#)
            == [.itemCompleted(.toolCall(ToolCall(id: "t", name: "memory", arguments: #"{"op":"list"}"#)))])
        // Redacted thinking is kept whole, to be sent back as it came.
        _ = try decoder.decode(#"{"type":"content_block_start","index":1,"content_block":{"type":"redacted_thinking","data":"xyz"}}"#)
        #expect(try decoder.decode(#"{"type":"content_block_stop","index":1}"#) == [.itemCompleted(.reasoning(
            Reasoning(text: "", opaque: #"{"data":"xyz","type":"redacted_thinking"}"#, provider: "a")))])
        // Servers that don't sign their thinking: readable, nothing to resume.
        _ = try decoder.decode(#"{"type":"content_block_start","index":2,"content_block":{"type":"thinking","thinking":"Plain"}}"#)
        #expect(try decoder.decode(#"{"type":"content_block_stop","index":2}"#)
            == [.itemCompleted(.reasoning(Reasoning(text: "Plain")))])

        _ = try decoder.decode(#"{"type":"message_delta","delta":{"stop_reason":"refusal"},"usage":{"output_tokens":3}}"#)
        #expect(try decoder.decode(#"{"type":"message_stop"}"#).last == .finished(.other("refusal")))
        #expect(AnthropicStreamDecoder.stop("max_tokens") == .maxTokens)
        #expect(throws: KuriError.self) {
            try decoder.decode(#"{"type":"error","error":{"type":"overloaded_error","message":"Overloaded"}}"#)
        }
    }

    @Test func buildsAlternatingMessagesAndReplaysOnlyCurrentThinking() throws {
        let request = InferenceRequest(
            model: "claude-opus-5-5",
            instructions: "Be brief.",
            items: [
                .message(Message(role: .user, text: "Plan a trip")),
                .reasoning(Reasoning(text: "old", opaque: "s0", provider: "anthropic")),
                .message(Message(role: .assistant, text: "Where to?")),
                .message(Message(role: .user, text: "Kyoto")),
                .reasoning(Reasoning(text: "think", opaque: "s1", provider: "anthropic")),
                .reasoning(Reasoning(text: "foreign", opaque: "enc", provider: "openai")),
                .toolCall(ToolCall(id: "call.1", name: "tasklist", arguments: #"{"tasks":[]}"#)),
                .toolResult(ToolResult(callID: "call.1", output: "ok")),
                .message(Message(role: .user, text: "Add a deadline")),  // queued, joins the round
                .toolResult(ToolResult(callID: "gone", output: "orphan")),
                .message(Message(role: .assistant, text: "Done.")),
                .message(Message(role: .assistant, text: "  ")),
            ],
            tools: [ToolSpec(name: "tasklist", description: "d", parameters: ["type": "object"])],
            reasoningEffort: "high")
        let body = AnthropicMessagesProvider.body(for: request, provider: "anthropic")

        #expect(body["system"] == "Be brief.")
        #expect(body["max_tokens"] == .number(Double(AnthropicMessagesProvider.defaultMaxTokens)))
        #expect(body["output_config"] == ["effort": "high"])
        #expect(body["thinking"]?["block_binding"] == ["prefix_mismatch_behavior": "drop_block"])
        #expect(body["tools"] == [["name": "tasklist", "description": "d", "input_schema": ["type": "object"]]])
        #expect(body["messages"] == [
            ["role": "user", "content": [["type": "text", "text": "Plan a trip"]]],
            ["role": "assistant", "content": [["type": "text", "text": "Where to?"]]],
            ["role": "user", "content": [["type": "text", "text": "Kyoto"]]],
            ["role": "assistant", "content": [
                ["type": "thinking", "thinking": "think", "signature": "s1"],
                ["type": "tool_use", "id": "call_1", "name": "tasklist", "input": ["tasks": []]],
            ]],
            ["role": "user", "content": [
                ["type": "tool_result", "tool_use_id": "call_1", "content": "ok"],
                ["type": "text", "text": "Add a deadline"],
            ]],
            ["role": "assistant", "content": [["type": "text", "text": "Done."]]],
            // Never end on the assistant: that would be a prefill.
            ["role": "user", "content": [["type": "text", "text": "Continue."]]],
        ])
    }

    @Test func addsProtocolHeadersAndKeepsConfiguredBetas() {
        let headers = AnthropicMessagesProvider.protocolHeaders(merging: ["Anthropic-Beta": "some-beta", "x-api-key": "k"])
        #expect(headers["anthropic-version"] == AnthropicMessagesProvider.apiVersion)
        #expect(headers["Anthropic-Beta"] == "some-beta,\(AnthropicMessagesProvider.thinkingBeta)")
        #expect(headers["anthropic-beta"] == nil)
        let pinned = AnthropicMessagesProvider.protocolHeaders(merging: ["anthropic-version": "2023-06-01"])
        #expect(pinned["anthropic-version"] == "2023-06-01")
    }

    @Test func discoversModelsAcrossPages() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [AnthropicModelsStub.self]
        let factory = ProviderFactory(session: URLSession(configuration: configuration))
        let models = try await factory.discoverModels(
            name: "anthropic",
            config: ProviderConfig(format: .anthropicMessages, baseURL: URL(string: "http://anthropic.test/v1"),
                                   apiKey: .literal("k")))
        #expect(models == ["claude-haiku-5-5", "claude-opus-5-5", "claude-sonnet-5-5"])
        let requests = AnthropicModelsStub.requests.withLock { $0 }
        #expect(requests.map(\.query) == ["limit=1000", "limit=1000&after_id=claude-sonnet-5-5"])
        #expect(requests.allSatisfy { $0.key == "k" && $0.version == AnthropicMessagesProvider.apiVersion })
    }
}

final class AnthropicModelsStub: URLProtocol, @unchecked Sendable {
    struct Seen: Sendable { var query: String?, key: String?, version: String? }
    static let requests = Mutex<[Seen]>([])

    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "anthropic.test" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let query = request.url?.query
        Self.requests.withLock {
            $0.append(Seen(query: query, key: request.value(forHTTPHeaderField: "x-api-key"),
                           version: request.value(forHTTPHeaderField: "anthropic-version")))
        }
        let body = query?.contains("after_id") == true
            ? #"{"data":[{"id":"claude-haiku-5-5"}],"has_more":false,"last_id":"claude-haiku-5-5"}"#
            : #"{"data":[{"id":"claude-opus-5-5"},{"id":"claude-sonnet-5-5"}],"has_more":true,"last_id":"claude-sonnet-5-5"}"#
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil,
                                                              headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
