import Foundation
import KuriCore
import KuriStore

/// Something the model can call.
public protocol Tool: Sendable {
    var spec: ToolSpec { get }
    /// The policy when neither the user nor a config file overrides it.
    var defaultPolicy: ToolPolicy { get }
    /// Read-only tools may run in parallel with each other.
    var isReadOnly: Bool { get }

    func run(arguments: Data, context: ToolContext) async throws -> ToolOutput
}

extension Tool {
    public var defaultPolicy: ToolPolicy { .allow }
    public var isReadOnly: Bool { false }

    /// Decodes the model's JSON arguments, turning failures into an error
    /// message the model can act on.
    public func decode<T: Decodable>(_ type: T.Type, from arguments: Data) throws -> T {
        do {
            return try JSONDecoder().decode(type, from: arguments.isEmpty ? Data("{}".utf8) : arguments)
        } catch {
            throw KuriError.invalidToolArguments(tool: spec.name, reason: String(describing: error))
        }
    }
}

public struct ToolOutput: Sendable, Hashable {
    public var text: String
    public var isError: Bool

    public init(_ text: String, isError: Bool = false) {
        self.text = text
        self.isError = isError
    }

    public static func error(_ text: String) -> ToolOutput {
        ToolOutput(text, isError: true)
    }
}

/// What a tool knows about the call it's serving.
public struct ToolContext: Sendable {
    public var conversationID: UUID
    public var turnID: UUID
    public var callID: String
    public var folders: [ConversationFolder]
    public var store: Store
    public var interaction: any UserInteraction
    /// Output as it comes, for tools that print over time (the shell).
    public var progress: @Sendable (String) -> Void

    public init(conversationID: UUID, turnID: UUID, callID: String, folders: [ConversationFolder],
                store: Store, interaction: any UserInteraction, progress: @escaping @Sendable (String) -> Void = { _ in }) {
        self.conversationID = conversationID
        self.turnID = turnID
        self.callID = callID
        self.folders = folders
        self.store = store
        self.interaction = interaction
        self.progress = progress
    }
}

/// The bridge to whoever is driving the conversation: the app's UI today,
/// a remote client later.
public protocol UserInteraction: Sendable {
    /// Asks the user and waits. Returns answers keyed by question id.
    func clarify(_ request: ClarifyRequest) async throws -> [String: String]
    /// Asks whether a tool call may run.
    func approve(_ request: ApprovalRequest) async throws -> Bool
}

public struct ClarifyRequest: Codable, Sendable, Hashable {
    public struct Question: Codable, Sendable, Hashable {
        public var id: String
        public var question: String
        /// Suggested answers. The user may still write their own.
        public var options: [String]?

        public init(id: String, question: String, options: [String]? = nil) {
            self.id = id
            self.question = question
            self.options = options
        }
    }

    public var conversationID: UUID
    public var callID: String
    public var questions: [Question]

    public init(conversationID: UUID, callID: String, questions: [Question]) {
        self.conversationID = conversationID
        self.callID = callID
        self.questions = questions
    }
}

public struct ApprovalRequest: Codable, Sendable, Hashable {
    public var conversationID: UUID
    public var callID: String
    public var tool: String
    public var arguments: String

    public init(conversationID: UUID, callID: String, tool: String, arguments: String) {
        self.conversationID = conversationID
        self.callID = callID
        self.tool = tool
        self.arguments = arguments
    }
}
