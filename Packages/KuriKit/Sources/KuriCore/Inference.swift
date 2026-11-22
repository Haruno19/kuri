import Foundation

/// Identifies a model as `<provider>/<model>`.
///
/// The provider is everything before the first slash; the model id is
/// everything after it, slashes included (`openrouter/meta/llama-4`).
public struct ModelRef: Sendable, Hashable, Codable, CustomStringConvertible {
    public var provider: String
    public var model: String

    public init(provider: String, model: String) {
        self.provider = provider
        self.model = model
    }

    public init?(_ string: String) {
        guard let slash = string.firstIndex(of: "/") else { return nil }
        let provider = String(string[..<slash])
        let model = String(string[string.index(after: slash)...])
        guard !provider.isEmpty, !model.isEmpty else { return nil }
        self.init(provider: provider, model: model)
    }

    public var description: String { "\(provider)/\(model)" }

    public init(from decoder: any Decoder) throws {
        let string = try decoder.singleValueContainer().decode(String.self)
        guard let ref = ModelRef(string) else {
            throw DecodingError.dataCorrupted(.init(
                codingPath: decoder.codingPath,
                debugDescription: "Expected \"<provider>/<model>\", got \"\(string)\""))
        }
        self = ref
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(description)
    }
}

/// What a tool looks like to the model.
public struct ToolSpec: Sendable, Hashable {
    public var name: String
    public var description: String
    /// JSON Schema for the arguments object.
    public var parameters: JSONValue

    public init(name: String, description: String, parameters: JSONValue) {
        self.name = name
        self.description = description
        self.parameters = parameters
    }
}

/// Everything a provider needs for one request.
///
/// Kuri is stateless towards providers: `items` is the full history the
/// model should see, rebuilt from the database each time.
public struct InferenceRequest: Sendable {
    public var model: String
    public var instructions: String
    public var items: [Item.Payload]
    public var tools: [ToolSpec]
    public var maxOutputTokens: Int?
    /// Provider-defined effort level ("low", "medium", "high"), if supported.
    public var reasoningEffort: String?

    public init(
        model: String,
        instructions: String,
        items: [Item.Payload],
        tools: [ToolSpec] = [],
        maxOutputTokens: Int? = nil,
        reasoningEffort: String? = nil
    ) {
        self.model = model
        self.instructions = instructions
        self.items = items
        self.tools = tools
        self.maxOutputTokens = maxOutputTokens
        self.reasoningEffort = reasoningEffort
    }
}

/// The stream every provider adapter produces, whatever its wire format.
///
/// Deltas are for display. Completed items are what gets persisted: the
/// agent never reassembles deltas itself.
public enum InferenceEvent: Sendable, Hashable {
    case textDelta(String)
    case reasoningDelta(String)
    case toolCallStarted(callID: String, name: String)
    case toolCallArgumentsDelta(callID: String, delta: String)
    case itemCompleted(Item.Payload)
    case usage(Usage)
    case finished(StopReason)
}

public struct Usage: Sendable, Hashable, Codable {
    public var inputTokens: Int
    public var outputTokens: Int
    public var reasoningTokens: Int
    public var cachedInputTokens: Int

    public init(inputTokens: Int = 0, outputTokens: Int = 0, reasoningTokens: Int = 0, cachedInputTokens: Int = 0) {
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.reasoningTokens = reasoningTokens
        self.cachedInputTokens = cachedInputTokens
    }

    public static func + (lhs: Usage, rhs: Usage) -> Usage {
        Usage(
            inputTokens: lhs.inputTokens + rhs.inputTokens,
            outputTokens: lhs.outputTokens + rhs.outputTokens,
            reasoningTokens: lhs.reasoningTokens + rhs.reasoningTokens,
            cachedInputTokens: lhs.cachedInputTokens + rhs.cachedInputTokens)
    }
}

public enum StopReason: Sendable, Hashable {
    case endTurn
    case toolUse
    case maxTokens
    case cancelled
    case other(String)

    public var rawValue: String {
        switch self {
        case .endTurn: "end_turn"
        case .toolUse: "tool_use"
        case .maxTokens: "max_tokens"
        case .cancelled: "cancelled"
        case .other(let value): value
        }
    }

    public init(rawValue: String) {
        self = switch rawValue {
        case "end_turn": .endTurn
        case "tool_use": .toolUse
        case "max_tokens": .maxTokens
        case "cancelled": .cancelled
        default: .other(rawValue)
        }
    }
}

/// How a tool may run without asking.
public enum ToolPolicy: String, Codable, Sendable, Hashable {
    case allow
    case ask
    case deny
}
