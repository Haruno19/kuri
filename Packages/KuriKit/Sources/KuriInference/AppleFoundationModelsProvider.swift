import Foundation
import FoundationModels
import KuriCore

/// Apple's on-device model, through the FoundationModels framework:
/// offline, free, and private.
///
/// Text only. Its context window is small (4,096 tokens), Kuri's tool
/// definitions alone would fill most of it, and FoundationModels runs tools
/// inside its own session, outside Kuri's policies and persistence. So the
/// model gets no tools, and is best used for chat and as the utility model
/// (titles, summaries).
///
/// Stateless like every adapter: each request becomes a fresh session over a
/// transcript rebuilt from the conversation's items.
public struct AppleFoundationModelsProvider: InferenceProvider {
    /// The only model: `SystemLanguageModel.default`.
    public static let modelID = "default"

    public init() {}

    public var supportsTools: Bool { false }

    public func stream(_ request: InferenceRequest) -> AsyncThrowingStream<InferenceEvent, any Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let model = SystemLanguageModel.default
                    try Self.checkAvailability(of: model)
                    let conversation = Self.conversation(for: request)
                    let session = LanguageModelSession(model: model, tools: [],
                                                       transcript: Self.transcript(for: conversation))
                    let options = GenerationOptions(maximumResponseTokens: request.maxOutputTokens)

                    var text = ""
                    for try await snapshot in session.streamResponse(to: conversation.prompt, options: options) {
                        let content = snapshot.content
                        if content.hasPrefix(text), content.count > text.count {
                            continuation.yield(.textDelta(String(content.dropFirst(text.count))))
                        }
                        text = content
                    }
                    continuation.yield(.itemCompleted(.message(Message(role: .assistant, text: text))))
                    continuation.yield(.finished(.endTurn))
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: Self.describe(error))
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// `["default"]` when the model can run on this Mac; otherwise why not.
    public static func availableModels() throws -> [String] {
        try checkAvailability(of: .default)
        return [modelID]
    }

    // MARK: Transcript

    /// The conversation as alternating user and assistant text, ending with
    /// the prompt to answer.
    struct Conversation: Equatable {
        enum Side: Equatable { case user, assistant }
        var instructions: String
        var turns: [(side: Side, text: String)]
        var prompt: String

        static func == (a: Conversation, b: Conversation) -> Bool {
            a.instructions == b.instructions && a.prompt == b.prompt
                && a.turns.map(\.side) == b.turns.map(\.side) && a.turns.map(\.text) == b.turns.map(\.text)
        }
    }

    /// Items from any model become text on the right side: tool calls and
    /// results from earlier turns (with other models) are described, not
    /// replayed as tool entries, since this model has no tools.
    static func conversation(for request: InferenceRequest) -> Conversation {
        var turns: [(side: Conversation.Side, text: String)] = []
        func add(_ side: Conversation.Side, _ text: String) {
            guard !text.isEmpty else { return }
            if let last = turns.last, last.side == side {
                turns[turns.count - 1].text += "\n\n" + text
            } else {
                turns.append((side, text))
            }
        }
        for item in request.items {
            switch item {
            case .message(let message): add(message.role == .user ? .user : .assistant, message.text)
            case .toolCall(let call): add(.assistant, "(Used the tool \(call.name) with \(call.arguments).)")
            case .toolResult(let result): add(.user, "(Tool result: \(result.output))")
            case .compaction(let compaction): add(.user, "Summary of the conversation so far:\n\(compaction.summary)")
            case .reasoning: continue
            }
        }
        // The session answers a prompt: the trailing user text, or a nudge
        // when the conversation ends on the assistant's side (Continue).
        var prompt = "Continue."
        if let last = turns.last, last.side == .user {
            prompt = last.text
            turns.removeLast()
        }
        return Conversation(instructions: request.instructions, turns: turns, prompt: prompt)
    }

    static func transcript(for conversation: Conversation) -> Transcript {
        var entries: [Transcript.Entry] = [
            .instructions(Transcript.Instructions(segments: [.text(.init(content: conversation.instructions))],
                                                  toolDefinitions: [])),
        ]
        for turn in conversation.turns {
            switch turn.side {
            case .user: entries.append(.prompt(Transcript.Prompt(segments: [.text(.init(content: turn.text))])))
            case .assistant: entries.append(.response(Transcript.Response(assetIDs: [], segments: [.text(.init(content: turn.text))])))
            }
        }
        return Transcript(entries: entries)
    }

    // MARK: Errors

    static func checkAvailability(of model: SystemLanguageModel) throws {
        switch model.availability {
        case .available:
            return
        case .unavailable(.deviceNotEligible):
            throw KuriError.provider("This Mac can't run Apple's on-device model.")
        case .unavailable(.appleIntelligenceNotEnabled):
            throw KuriError.provider("Turn on Apple Intelligence in System Settings to use Apple's on-device model.")
        case .unavailable(.modelNotReady):
            throw KuriError.provider("Apple's on-device model isn't ready yet (it may still be downloading). Try again later.")
        case .unavailable:
            throw KuriError.provider("Apple's on-device model is unavailable.")
        }
    }

    static func describe(_ error: any Error) -> any Error {
        if error is KuriError || error is CancellationError { return error }
        if let error = error as? LanguageModelSession.GenerationError {
            switch error {
            case .exceededContextWindowSize:
                return KuriError.provider("The conversation is longer than the on-device model's context. Compact it, or switch model.")
            case .guardrailViolation:
                return KuriError.provider("Apple's on-device model declined: the request tripped its safety guardrails.")
            case .unsupportedLanguageOrLocale:
                return KuriError.provider("Apple's on-device model doesn't support this language.")
            default:
                break
            }
        }
        return KuriError.provider("Apple's on-device model: \(error.localizedDescription)")
    }
}
