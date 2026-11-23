import Foundation
import KuriCore

/// The Open Responses wire format (`POST /responses`), spoken by OpenAI,
/// Ollama, LM Studio, vLLM and others.
///
/// Always stateless: `store: false`, no `previous_response_id`. Local
/// runtimes only implement the stateless flavour, and Kuri's database is
/// the source of truth anyway.
public struct OpenResponsesProvider: InferenceProvider {
    public let name: String
    public let baseURL: URL
    let headers: [String: String]
    let session: URLSession

    public init(name: String, baseURL: URL, headers: [String: String] = [:], session: URLSession = .shared) {
        self.name = name
        self.baseURL = baseURL
        self.headers = headers
        self.session = session
    }

    public func stream(_ request: InferenceRequest) -> AsyncThrowingStream<InferenceEvent, any Error> {
        let events = HTTP.eventStream(
            session: session, url: baseURL.appending(path: "responses"), headers: headers,
            body: Self.body(for: request, provider: name))
        let provider = name
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    var decoder = OpenResponsesStreamDecoder(provider: provider)
                    for try await sse in events {
                        if sse.data == "[DONE]" { break }
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

    // MARK: Request

    static func body(for request: InferenceRequest, provider: String) -> JSONValue {
        var body: [String: JSONValue] = [
            "model": .string(request.model),
            "instructions": .string(request.instructions),
            "input": .array(request.items.compactMap { input($0, provider: provider) }),
            "stream": true,
            "store": false,
        ]
        if !request.tools.isEmpty {
            body["tools"] = .array(request.tools.map { tool in
                ["type": "function", "name": .string(tool.name), "description": .string(tool.description),
                 "parameters": tool.parameters]
            })
        }
        if let max = request.maxOutputTokens { body["max_output_tokens"] = .number(Double(max)) }
        if let effort = request.reasoningEffort { body["reasoning"] = ["effort": .string(effort)] }
        return .object(body)
    }

    private static func input(_ payload: Item.Payload, provider: String) -> JSONValue? {
        switch payload {
        case .message(let message):
            let partType = message.role == .user ? "input_text" : "output_text"
            let part: JSONValue = ["type": .string(partType), "text": .string(message.text)]
            return ["type": "message", "role": .string(message.role.rawValue), "content": [part]]
        case .reasoning(let reasoning):
            // Only worth sending back when there's opaque state to resume
            // from, and only to the provider that produced it.
            guard let opaque = reasoning.opaque, reasoning.provider == provider else { return nil }
            return ["type": "reasoning", "summary": [], "encrypted_content": .string(opaque)]
        case .toolCall(let call):
            return ["type": "function_call", "call_id": .string(call.id), "name": .string(call.name),
                    "arguments": .string(call.arguments)]
        case .toolResult(let result):
            return ["type": "function_call_output", "call_id": .string(result.callID), "output": .string(result.output)]
        case .compaction(let compaction):
            return ["type": "message", "role": "user", "content": [
                ["type": "input_text", "text": .string("Summary of the conversation so far:\n\n\(compaction.summary)")],
            ]]
        }
    }
}

/// Turns Open Responses stream events into `InferenceEvent`s.
struct OpenResponsesStreamDecoder {
    let provider: String
    /// Argument deltas reference the output item id; Kuri tracks calls by call id.
    private var callIDs: [String: String] = [:]
    private var sawToolCall = false

    init(provider: String) {
        self.provider = provider
    }

    mutating func decode(_ data: String) throws -> [InferenceEvent] {
        let event = try JSONDecoder().decode(StreamEvent.self, from: Data(data.utf8))
        switch event.type {
        case "response.output_text.delta":
            return event.delta.map { [.textDelta($0)] } ?? []

        case "response.reasoning_text.delta", "response.reasoning_summary_text.delta":
            return event.delta.map { [.reasoningDelta($0)] } ?? []

        case "response.output_item.added":
            guard let item = event.item, item.type == "function_call",
                  let callID = item.call_id, let name = item.name else { return [] }
            if let id = item.id { callIDs[id] = callID }
            return [.toolCallStarted(callID: callID, name: name)]

        case "response.function_call_arguments.delta":
            guard let itemID = event.item_id, let callID = callIDs[itemID], let delta = event.delta else { return [] }
            return [.toolCallArgumentsDelta(callID: callID, delta: delta)]

        case "response.output_item.done":
            guard let payload = event.item.flatMap(payload) else { return [] }
            if case .toolCall = payload { sawToolCall = true }
            return [.itemCompleted(payload)]

        case "response.completed":
            return usage(event.response) + [.finished(sawToolCall ? .toolUse : .endTurn)]

        case "response.incomplete":
            let reason = event.response?.incomplete_details?.reason ?? "incomplete"
            return usage(event.response) + [.finished(reason == "max_output_tokens" ? .maxTokens : .other(reason))]

        case "response.failed":
            throw KuriError.provider(event.response?.error?.message ?? "The response failed.")

        case "error":
            throw KuriError.provider(event.message ?? event.error?.message ?? "The provider reported an error.")

        default:
            return []
        }
    }

    private func payload(_ item: StreamEvent.OutputItem) -> Item.Payload? {
        switch item.type {
        case "message":
            let text = (item.content ?? []).compactMap { $0.text }.joined()
            return .message(Message(role: .assistant, text: text))
        case "function_call":
            guard let callID = item.call_id, let name = item.name else { return nil }
            return .toolCall(ToolCall(id: callID, name: name, arguments: item.arguments ?? "{}"))
        case "reasoning":
            let parts = (item.summary ?? []) + (item.content ?? [])
            let text = parts.compactMap(\.text).joined(separator: "\n\n")
            guard !text.isEmpty || item.encrypted_content != nil else { return nil }
            return .reasoning(Reasoning(text: text, opaque: item.encrypted_content,
                                        provider: item.encrypted_content == nil ? nil : provider))
        default:
            return nil
        }
    }

    private func usage(_ response: StreamEvent.Response?) -> [InferenceEvent] {
        guard let usage = response?.usage else { return [] }
        return [.usage(Usage(
            inputTokens: usage.input_tokens ?? 0,
            outputTokens: usage.output_tokens ?? 0,
            reasoningTokens: usage.output_tokens_details?.reasoning_tokens ?? 0,
            cachedInputTokens: usage.input_tokens_details?.cached_tokens ?? 0))]
    }
}

/// The subset of the Open Responses stream schema Kuri reads.
private struct StreamEvent: Decodable {
    let type: String
    let delta: String?
    let item_id: String?
    let item: OutputItem?
    let response: Response?
    let message: String?
    let error: ErrorBody?

    struct OutputItem: Decodable {
        let type: String
        let id: String?
        let call_id: String?
        let name: String?
        let arguments: String?
        let content: [Part]?
        let summary: [Part]?
        let encrypted_content: String?
    }

    struct Part: Decodable {
        let type: String
        let text: String?
    }

    struct Response: Decodable {
        let usage: UsageBody?
        let incomplete_details: Incomplete?
        let error: ErrorBody?
    }

    struct UsageBody: Decodable {
        let input_tokens: Int?
        let output_tokens: Int?
        let input_tokens_details: InputDetails?
        let output_tokens_details: OutputDetails?
    }

    struct InputDetails: Decodable { let cached_tokens: Int? }
    struct OutputDetails: Decodable { let reasoning_tokens: Int? }
    struct Incomplete: Decodable { let reason: String? }
    struct ErrorBody: Decodable { let message: String? }
}
