import Foundation
import KuriCore

/// The Anthropic Messages wire format (`POST /messages`), spoken by
/// Anthropic's API and by servers that copy it (Ollama among them).
///
/// Every request turns on adaptive thinking with summaries, so the model
/// decides how much to think and Kuri has something to show; it needs a
/// Claude 4.6 model or later. The whole conversation is resent each time,
/// so the request asks for automatic prompt caching of its prefix.
public struct AnthropicMessagesProvider: InferenceProvider {
    public static let defaultBaseURL = URL(string: "https://api.anthropic.com/v1")!
    static let apiVersion = "2026-10-21"
    /// Lets a request ask for stale thinking to be dropped instead of refused.
    static let thinkingBeta = "thinking-binding-controls-2026-08-01"
    /// The format requires an output cap. This one fits every current model
    /// and leaves room for thinking, which counts against it.
    static let defaultMaxTokens = 32_000

    public let name: String
    public let baseURL: URL
    let headers: [String: String]
    let session: URLSession

    public init(name: String, baseURL: URL = Self.defaultBaseURL, headers: [String: String] = [:],
                session: URLSession = .shared) {
        self.name = name
        self.baseURL = baseURL
        self.headers = Self.protocolHeaders(merging: headers)
        self.session = session
    }

    public func stream(_ request: InferenceRequest) -> AsyncThrowingStream<InferenceEvent, any Error> {
        let events = HTTP.eventStream(
            session: session, url: baseURL.appending(path: "messages"), headers: headers,
            body: Self.body(for: request, provider: name))
        let provider = name
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    var decoder = AnthropicStreamDecoder(provider: provider)
                    for try await sse in events {
                        for event in try decoder.decode(sse.data) { continuation.yield(event) }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// The version and beta headers, unless the configuration sets them;
    /// configured betas are kept alongside Kuri's.
    static func protocolHeaders(merging configured: [String: String]) -> [String: String] {
        var headers = configured
        func key(_ name: String) -> String? { headers.keys.first { $0.lowercased() == name } }
        if key("anthropic-version") == nil { headers["anthropic-version"] = apiVersion }
        if let beta = key("anthropic-beta") {
            if !headers[beta]!.contains(thinkingBeta) { headers[beta]! += ",\(thinkingBeta)" }
        } else {
            headers["anthropic-beta"] = thinkingBeta
        }
        return headers
    }

    // MARK: Request

    static func body(for request: InferenceRequest, provider: String) -> JSONValue {
        var body: [String: JSONValue] = [
            "model": .string(request.model),
            "max_tokens": .number(Double(request.maxOutputTokens ?? defaultMaxTokens)),
            "messages": .array(messages(from: request.items, provider: provider)),
            "stream": true,
            "cache_control": ["type": "ephemeral"],
            // A thinking block is only valid with the exact history it was
            // produced from. Kuri's instructions and tools can change during
            // a turn (memories, MCP servers): drop what no longer matches
            // rather than fail the request.
            "thinking": ["type": "adaptive", "display": "summarized",
                         "block_binding": ["prefix_mismatch_behavior": "drop_block"]],
        ]
        if !request.instructions.isEmpty { body["system"] = .string(request.instructions) }
        if !request.tools.isEmpty {
            body["tools"] = .array(request.tools.map { tool in
                ["name": .string(tool.name), "description": .string(tool.description),
                 "input_schema": tool.parameters == .null ? ["type": "object"] : tool.parameters]
            })
        }
        if let effort = request.reasoningEffort { body["output_config"] = ["effort": .string(effort)] }
        return .object(body)
    }

    /// Items become alternating user and assistant messages of content blocks.
    static func messages(from items: [Item.Payload], provider: String) -> [JSONValue] {
        // Thinking is replayed only for the current exchange (since the last
        // message from the user that isn't joining a tool round). Earlier
        // blocks were produced under earlier instructions, which change from
        // day to day, and dropping a leading run of them is always allowed.
        let exchangeStart = items.indices.last { index in
            startsUserTurn(items[index]) && (index == 0 || !isToolResult(items[index - 1]))
        } ?? 0

        var turns: [(role: String, blocks: [JSONValue])] = []
        var calls: Set<String> = []
        for (index, payload) in items.enumerated() {
            guard let entry = block(for: payload, provider: provider, replayThinking: index > exchangeStart)
            else { continue }
            let (role, block) = entry
            if case .toolCall(let call) = payload { calls.insert(call.id) }
            // A result whose call was summarized away would be refused.
            if case .toolResult(let result) = payload, !calls.contains(result.callID) { continue }
            if turns.last?.role == role {
                turns[turns.count - 1].blocks.append(block)
            } else {
                turns.append((role, [block]))
            }
        }
        // The conversation must end with the user: ending on the assistant
        // would be a prefill, which current models refuse (Continue).
        if turns.last?.role == "assistant" {
            turns.append(("user", [["type": "text", "text": "Continue."]]))
        }
        return turns.map { turn in
            // Tool results lead their message, ahead of any text.
            let results = turn.blocks.filter { $0["type"] == "tool_result" }
            let others = turn.blocks.filter { $0["type"] != "tool_result" }
            return ["role": .string(turn.role), "content": .array(results + others)]
        }
    }

    private static func block(for payload: Item.Payload, provider: String, replayThinking: Bool)
        -> (role: String, block: JSONValue)?
    {
        switch payload {
        case .message(let message):
            let text = message.text
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            return (message.role == .user ? "user" : "assistant", ["type": "text", "text": .string(text)])
        case .reasoning(let reasoning):
            guard replayThinking, reasoning.provider == provider, let opaque = reasoning.opaque else { return nil }
            // A redacted block is kept whole; a readable one by its signature.
            if opaque.hasPrefix("{"), let block = try? JSONDecoder().decode(JSONValue.self, from: Data(opaque.utf8)) {
                return ("assistant", block)
            }
            return ("assistant", ["type": "thinking", "thinking": .string(reasoning.text), "signature": .string(opaque)])
        case .toolCall(let call):
            var input: JSONValue = [:]
            if let parsed = try? JSONDecoder().decode(JSONValue.self, from: Data(call.arguments.utf8)),
               case .object = parsed { input = parsed }
            return ("assistant", ["type": "tool_use", "id": .string(toolUseID(call.id)), "name": .string(call.name),
                                  "input": input])
        case .toolResult(let result):
            var block: [String: JSONValue] = ["type": "tool_result", "tool_use_id": .string(toolUseID(result.callID))]
            if !result.output.isEmpty { block["content"] = .string(result.output) }
            if result.isError { block["is_error"] = true }
            return ("user", .object(block))
        case .compaction(let compaction):
            return ("user", ["type": "text", "text": .string("Summary of the conversation so far:\n\n\(compaction.summary)")])
        }
    }

    private static func startsUserTurn(_ payload: Item.Payload) -> Bool {
        switch payload {
        case .message(let message): message.role == .user
        case .compaction: true
        default: false
        }
    }

    private static func isToolResult(_ payload: Item.Payload) -> Bool {
        if case .toolResult = payload { true } else { false }
    }

    /// Call ids from other providers may use characters this format refuses.
    static func toolUseID(_ id: String) -> String {
        String(id.map { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_" || $0 == "-") ? $0 : "_" })
    }
}

/// Turns Messages stream events into `InferenceEvent`s.
struct AnthropicStreamDecoder {
    let provider: String
    private var blocks: [Int: Block] = [:]
    private var usage = StreamEvent.UsageBody()
    private var stopReason: String?

    private enum Block {
        case text(String)
        case thinking(text: String, signature: String)
        case redacted(JSONValue)
        case toolUse(id: String, name: String, json: String, initial: JSONValue?)
    }

    init(provider: String) {
        self.provider = provider
    }

    mutating func decode(_ data: String) throws -> [InferenceEvent] {
        let event = try JSONDecoder().decode(StreamEvent.self, from: Data(data.utf8))
        switch event.type {
        case "message_start":
            usage.merge(event.message?.usage)
            return []

        case "content_block_start":
            guard let index = event.index, let block = event.content_block else { return [] }
            switch block.type {
            case "text":
                let text = block.text ?? ""
                blocks[index] = .text(text)
                return text.isEmpty ? [] : [.textDelta(text)]
            case "thinking":
                let text = block.thinking ?? ""
                blocks[index] = .thinking(text: text, signature: block.signature ?? "")
                return text.isEmpty ? [] : [.reasoningDelta(text)]
            case "redacted_thinking":
                blocks[index] = .redacted(["type": "redacted_thinking", "data": .string(block.data ?? "")])
                return []
            case "tool_use":
                guard let id = block.id, let name = block.name else { return [] }
                blocks[index] = .toolUse(id: id, name: name, json: "", initial: block.input)
                return [.toolCallStarted(callID: id, name: name)]
            default:
                return []  // server tools, citations…: not used by Kuri
            }

        case "content_block_delta":
            guard let index = event.index, let delta = event.delta, let block = blocks[index] else { return [] }
            switch (block, delta.type) {
            case (.text(let text), "text_delta"):
                let piece = delta.text ?? ""
                blocks[index] = .text(text + piece)
                return [.textDelta(piece)]
            case (.thinking(let text, let signature), "thinking_delta"):
                let piece = delta.thinking ?? ""
                blocks[index] = .thinking(text: text + piece, signature: signature)
                return [.reasoningDelta(piece)]
            case (.thinking(let text, let signature), "signature_delta"):
                blocks[index] = .thinking(text: text, signature: signature + (delta.signature ?? ""))
                return []
            case (.toolUse(let id, let name, let json, let initial), "input_json_delta"):
                let piece = delta.partial_json ?? ""
                blocks[index] = .toolUse(id: id, name: name, json: json + piece, initial: initial)
                return piece.isEmpty ? [] : [.toolCallArgumentsDelta(callID: id, delta: piece)]
            default:
                return []
            }

        case "content_block_stop":
            guard let index = event.index, let block = blocks.removeValue(forKey: index) else { return [] }
            return completed(block).map { [.itemCompleted($0)] } ?? []

        case "message_delta":
            usage.merge(event.usage)
            if let reason = event.delta?.stop_reason { stopReason = reason }
            return []

        case "message_stop":
            return [.usage(usage.kuriUsage), .finished(Self.stop(stopReason))]

        case "error":
            throw KuriError.provider(event.error?.message ?? "The provider reported an error.")

        default:
            return []  // ping
        }
    }

    private func completed(_ block: Block) -> Item.Payload? {
        switch block {
        case .text(let text):
            return text.isEmpty ? nil : .message(Message(role: .assistant, text: text))
        case .thinking(let text, let signature):
            guard !text.isEmpty || !signature.isEmpty else { return nil }
            return .reasoning(Reasoning(text: text, opaque: signature.isEmpty ? nil : signature,
                                        provider: signature.isEmpty ? nil : provider))
        case .redacted(let block):
            return .reasoning(Reasoning(text: "", opaque: block.jsonString(), provider: provider))
        case .toolUse(let id, let name, let json, let initial):
            // Some servers send the whole input up front instead of deltas.
            let arguments = json.isEmpty ? (initial.map { $0.jsonString() } ?? "{}") : json
            return .toolCall(ToolCall(id: id, name: name, arguments: arguments))
        }
    }

    static func stop(_ reason: String?) -> StopReason {
        switch reason {
        case nil, "end_turn", "stop_sequence": .endTurn
        case "tool_use": .toolUse
        case "max_tokens": .maxTokens
        case let other?: .other(other)
        }
    }
}

/// The subset of the Messages stream schema Kuri reads.
private struct StreamEvent: Decodable {
    let type: String
    let index: Int?
    let content_block: ContentBlock?
    let delta: Delta?
    let message: MessageBody?
    let usage: UsageBody?
    let error: ErrorBody?

    struct ContentBlock: Decodable {
        let type: String
        let text: String?
        let thinking: String?
        let signature: String?
        let data: String?
        let id: String?
        let name: String?
        let input: JSONValue?
    }

    struct Delta: Decodable {
        let type: String?
        let text: String?
        let thinking: String?
        let signature: String?
        let partial_json: String?
        let stop_reason: String?
    }

    struct MessageBody: Decodable { let usage: UsageBody? }
    struct ErrorBody: Decodable { let message: String? }

    struct UsageBody: Decodable {
        var input_tokens: Int?
        var output_tokens: Int?
        var cache_creation_input_tokens: Int?
        var cache_read_input_tokens: Int?

        init() {}

        /// Later events carry running totals: the newest value wins.
        mutating func merge(_ other: UsageBody?) {
            guard let other else { return }
            input_tokens = other.input_tokens ?? input_tokens
            output_tokens = other.output_tokens ?? output_tokens
            cache_creation_input_tokens = other.cache_creation_input_tokens ?? cache_creation_input_tokens
            cache_read_input_tokens = other.cache_read_input_tokens ?? cache_read_input_tokens
        }

        /// Kuri counts cached input as part of the input, as other formats do.
        var kuriUsage: Usage {
            let cached = cache_read_input_tokens ?? 0
            return Usage(inputTokens: (input_tokens ?? 0) + (cache_creation_input_tokens ?? 0) + cached,
                         outputTokens: output_tokens ?? 0, cachedInputTokens: cached)
        }
    }
}
