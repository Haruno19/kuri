import Foundation

/// One entry in a conversation.
///
/// A conversation is an ordered list of items, modelled after the Open
/// Responses item types. Every provider adapter converts to and from this
/// shape, which is what makes switching model mid-conversation possible.
public struct Item: Identifiable, Sendable, Hashable {
    public var id: UUID
    public var conversationID: UUID
    /// The turn that produced this item. `nil` only for items created
    /// outside a turn: the user's plan edits, summaries made on request.
    public var turnID: UUID?
    public var createdAt: Date
    public var payload: Payload

    public init(
        id: UUID = UUID(),
        conversationID: UUID,
        turnID: UUID? = nil,
        createdAt: Date = .now,
        payload: Payload
    ) {
        self.id = id
        self.conversationID = conversationID
        self.turnID = turnID
        self.createdAt = createdAt
        self.payload = payload
    }

    public enum Payload: Sendable, Hashable {
        case message(Message)
        case reasoning(Reasoning)
        case toolCall(ToolCall)
        case toolResult(ToolResult)
        /// Replaces every item before it when the next request is built.
        case compaction(Compaction)
    }
}

public enum Role: String, Codable, Sendable, Hashable {
    case user
    case assistant
}

public struct Message: Sendable, Hashable {
    public var role: Role
    public var text: String

    public init(role: Role, text: String) {
        self.role = role
        self.text = text
    }
}

public struct Reasoning: Codable, Sendable, Hashable {
    /// What the provider let us read: raw reasoning or a summary of it.
    public var text: String
    /// Provider data that must be sent back unchanged for the model to
    /// resume its reasoning (e.g. OpenAI's encrypted content, Anthropic's
    /// signature). Only meaningful to the provider that produced it.
    public var opaque: String?
    /// The provider that produced `opaque`.
    public var provider: String?

    public init(text: String, opaque: String? = nil, provider: String? = nil) {
        self.text = text
        self.opaque = opaque
        self.provider = provider
    }
}

public struct ToolCall: Codable, Sendable, Hashable {
    /// The provider's call id; the matching `ToolResult` carries the same one.
    public var id: String
    public var name: String
    /// The arguments as the model produced them: JSON text, not yet validated.
    public var arguments: String

    public init(id: String, name: String, arguments: String) {
        self.id = id
        self.name = name
        self.arguments = arguments
    }
}

public struct ToolResult: Codable, Sendable, Hashable {
    public var callID: String
    public var output: String
    public var isError: Bool

    public init(callID: String, output: String, isError: Bool = false) {
        self.callID = callID
        self.output = output
        self.isError = isError
    }
}

/// A summary standing in for the start of a conversation.
///
/// The item is appended at the end like any other, but it replaces only
/// the items up to and including `throughItemID`; the ones after that stay
/// verbatim. That keeps storage append-only while the latest exchange
/// survives compaction word for word.
public struct Compaction: Codable, Sendable, Hashable {
    public var summary: String
    /// The last item the summary covers. `nil`: everything before this item.
    public var throughItemID: UUID?

    public init(summary: String, throughItemID: UUID? = nil) {
        self.summary = summary
        self.throughItemID = throughItemID
    }
}

// MARK: - Codable

/// Stored the Open Responses way, as a list of content parts, which is how
/// messages have always been stored: text parts are all there is.
extension Message: Codable {
    private enum CodingKeys: String, CodingKey { case role, content }

    private struct Part: Codable {
        var type = "text"
        var text: String?
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        role = try container.decode(Role.self, forKey: .role)
        text = try container.decode([Part].self, forKey: .content).compactMap(\.text).joined()
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(role, forKey: .role)
        try container.encode([Part(text: text)], forKey: .content)
    }
}

extension Item.Payload {
    /// The stable name of the payload's case, as stored in the database.
    public var kind: String {
        switch self {
        case .message: "message"
        case .reasoning: "reasoning"
        case .toolCall: "toolCall"
        case .toolResult: "toolResult"
        case .compaction: "compaction"
        }
    }

    /// The text worth indexing for search.
    public var searchableText: String {
        switch self {
        case .message(let message): message.text
        case .reasoning(let reasoning): reasoning.text
        case .toolCall(let call): "\(call.name) \(call.arguments)"
        case .toolResult(let result): result.output
        case .compaction(let compaction): compaction.summary
        }
    }

    /// Encodes the associated value alone; `kind` says how to decode it.
    public func encodedBody() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return switch self {
        case .message(let value): try encoder.encode(value)
        case .reasoning(let value): try encoder.encode(value)
        case .toolCall(let value): try encoder.encode(value)
        case .toolResult(let value): try encoder.encode(value)
        case .compaction(let value): try encoder.encode(value)
        }
    }

    public init(kind: String, body: Data) throws {
        let decoder = JSONDecoder()
        switch kind {
        case "message": self = .message(try decoder.decode(Message.self, from: body))
        case "reasoning": self = .reasoning(try decoder.decode(Reasoning.self, from: body))
        case "toolCall": self = .toolCall(try decoder.decode(ToolCall.self, from: body))
        case "toolResult": self = .toolResult(try decoder.decode(ToolResult.self, from: body))
        case "compaction": self = .compaction(try decoder.decode(Compaction.self, from: body))
        default: throw KuriError.unknownItemKind(kind)
        }
    }
}
