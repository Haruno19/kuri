import Foundation
import KuriCore
import KuriMCP
import KuriSandbox
import KuriStore
import KuriTools
import Synchronization

/// Everything the engine tells its observers. The app's UI subscribes to
/// these; a future network server would forward the same stream.
public enum EngineEvent: Sendable {
    case conversationUpdated(Conversation)
    case conversationDeleted(UUID)
    case itemAdded(Item)
    /// Live output of the model, for display only. The finished items
    /// arrive separately as `itemAdded`.
    case inference(conversationID: UUID, InferenceEvent)
    case turnStarted(Turn)
    case turnFinished(conversationID: UUID, turnID: UUID, TurnOutcome)
    /// A request to the turn's model failed before it produced anything, so
    /// the turn goes on with the next of its fallbacks.
    case modelFallback(conversationID: UUID, from: ModelRef, to: ModelRef, reason: String)
    /// A summary of the conversation is being written (true) or done (false).
    case compacting(conversationID: UUID, Bool)
    /// A tool call finished; its result also arrives as `itemAdded`.
    case toolFinished(conversationID: UUID, call: ToolCall, output: ToolOutput)
    case inputRequested(InputRequest)
    case inputResolved(requestID: UUID)
    case configReloaded
    case configFailed(String)
    /// Tools were added, removed, or their policies changed.
    case toolsChanged
    case memoriesChanged
    case mcpServersChanged([MCPServerStatus])
    case sandboxChanged(SandboxStatus)
    /// Messages waiting for a running turn's next step.
    case queueChanged(conversationID: UUID, [QueuedMessage])
    case foldersChanged(conversationID: UUID, [ConversationFolder])
}

public enum TurnOutcome: Sendable, Hashable {
    case completed(StopReason)
    case failed(String)
    case cancelled
}

/// A question for the user that blocks a turn until it's answered.
public struct InputRequest: Identifiable, Sendable, Hashable {
    public enum Kind: Sendable, Hashable {
        case clarify(ClarifyRequest)
        case approval(ApprovalRequest)
    }

    public var id: UUID
    public var kind: Kind

    public var conversationID: UUID {
        switch kind {
        case .clarify(let request): request.conversationID
        case .approval(let request): request.conversationID
        }
    }
}

public enum InputResponse: Sendable, Hashable {
    case answers([String: String])
    case approved(Bool)
}

/// A message sent while its conversation was busy.
public struct QueuedMessage: Identifiable, Sendable, Hashable {
    public var id: UUID
    public var text: String

    public init(id: UUID = UUID(), text: String) {
        self.id = id
        self.text = text
    }
}

/// Fans events out to any number of subscribers.
final class EventBroadcaster: Sendable {
    private let subscribers = Mutex<[UUID: AsyncStream<EngineEvent>.Continuation]>([:])

    func subscribe() -> AsyncStream<EngineEvent> {
        let (stream, continuation) = AsyncStream.makeStream(of: EngineEvent.self, bufferingPolicy: .unbounded)
        let id = UUID()
        subscribers.withLock { $0[id] = continuation }
        continuation.onTermination = { [weak self] _ in
            _ = self?.subscribers.withLock { $0.removeValue(forKey: id) }
        }
        return stream
    }

    func emit(_ event: EngineEvent) {
        for continuation in subscribers.withLock({ Array($0.values) }) {
            continuation.yield(event)
        }
    }
}
