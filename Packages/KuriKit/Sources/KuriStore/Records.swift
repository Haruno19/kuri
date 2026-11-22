import Foundation
import KuriCore

public struct Conversation: Identifiable, Sendable, Hashable {
    public var id: UUID
    public var parentID: UUID?
    public var title: String
    public var model: ModelRef?
    public var systemPrompt: String?
    public var pinned: Bool
    public var archived: Bool
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: UUID = UUID(),
        parentID: UUID? = nil,
        title: String = "",
        model: ModelRef? = nil,
        systemPrompt: String? = nil,
        pinned: Bool = false,
        archived: Bool = false,
        createdAt: Date = .now,
        updatedAt: Date = .now
    ) {
        self.id = id
        self.parentID = parentID
        self.title = title
        self.model = model
        self.systemPrompt = systemPrompt
        self.pinned = pinned
        self.archived = archived
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

/// A folder the model may work in, mounted in the conversation's container.
public struct ConversationFolder: Sendable, Hashable {
    public var path: String
    public var readOnly: Bool

    public init(path: String, readOnly: Bool = false) {
        self.path = path
        self.readOnly = readOnly
    }
}

public struct Turn: Identifiable, Sendable, Hashable {
    public enum Status: String, Sendable {
        case running
        case awaitingInput = "awaiting_input"
        case completed
        case failed
        case cancelled
    }

    public var id: UUID
    public var conversationID: UUID
    public var model: ModelRef
    public var status: Status
    public var stopReason: StopReason?
    public var error: String?
    public var usage: Usage
    public var startedAt: Date
    public var endedAt: Date?
}

public struct Memory: Identifiable, Sendable, Hashable {
    public enum Source: String, Sendable { case user, agent, review }
    public enum Status: String, Sendable { case active, archived }

    /// Short, human- and model-friendly handle (the row number), shown as
    /// `m12`. Updating a memory creates a new row, so it gets a new number.
    public var number: Int
    public var id: UUID
    public var content: String
    public var source: Source
    public var status: Status
    public var supersedesID: UUID?
    public var originConversationID: UUID?
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        number: Int,
        id: UUID = UUID(),
        content: String,
        source: Source,
        status: Status = .active,
        supersedesID: UUID? = nil,
        originConversationID: UUID? = nil,
        createdAt: Date = .now,
        updatedAt: Date = .now
    ) {
        self.number = number
        self.id = id
        self.content = content
        self.source = source
        self.status = status
        self.supersedesID = supersedesID
        self.originConversationID = originConversationID
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    /// `m12`
    public var handle: String { "m\(number)" }

    /// Parses `m12` or `12`.
    public static func number(fromHandle handle: String) -> Int? {
        let digits = handle.hasPrefix("m") ? handle.dropFirst() : Substring(handle)
        return Int(digits)
    }
}

public enum MemoryChange: Sendable, Hashable {
    case add(String)
    case update(number: Int, content: String)
    case remove(number: Int)
}

public enum MemoryChangeOutcome: Sendable, Hashable {
    case added(Memory)
    case updated(old: Int, new: Memory)
    case removed(Int)
}

public struct SearchHit: Sendable, Hashable {
    public var conversationID: UUID
    public var conversationTitle: String
    public var itemID: UUID
    public var seq: Int
    public var role: String?
    public var text: String
    public var createdAt: Date
}
