import Foundation
import KuriCore
import KuriInference
import KuriStore
import KuriTools
import Synchronization
import Testing
@testable import KuriAgent

/// Says a few words, then waits, as a model does mid-answer: only the
/// consumer's cancellation ends its stream.
private final class StallingProvider: InferenceProvider {
    func stream(_ request: InferenceRequest) -> AsyncThrowingStream<InferenceEvent, any Error> {
        AsyncThrowingStream { continuation in
            continuation.yield(.textDelta("Once upon a"))
        }
    }
}

@Suite struct CancellationTests {
    /// A cancelled stream ends without throwing (an `AsyncThrowingStream`
    /// returns `nil` to a cancelled consumer), so the turn must still be
    /// recorded as stopped, not as an answer that ended normally.
    @Test func stoppingMidAnswerCancelsTheTurn() async throws {
        let model = ModelRef(provider: "test", model: "m")
        let store = try Store(url: nil)
        let conversation = Conversation(model: model)
        try await store.createConversation(conversation)
        try await store.append(Item(conversationID: conversation.id,
                                    payload: .message(Message(role: .user, text: "Tell me a story"))))
        let turn = try await store.beginTurn(conversationID: conversation.id, model: model)
        let (streaming, started) = AsyncStream.makeStream(of: Void.self)
        let runner = TurnRunner(
            conversationID: conversation.id, turn: turn, provider: StallingProvider(),
            modelConfig: ModelConfigSnapshot(), instructions: "test", folders: [],
            registry: ToolRegistry(BuiltInTools.all), store: store, interaction: Answering(),
            limits: TurnLimits(), compactor: nil,
            emit: { event in
                if case .inference(_, .textDelta) = event { started.yield() }
            })

        let running = Task { await runner.run() }
        for await _ in streaming { break }
        running.cancel()

        #expect(await running.value == .cancelled)
        #expect(try await store.turns(of: conversation.id).first?.status == .cancelled)
    }
}
