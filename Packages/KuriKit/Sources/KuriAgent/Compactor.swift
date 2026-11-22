import Foundation
import KuriCore
import KuriInference
import KuriStore

/// Summarizes the start of a conversation into a `compaction` item, so it
/// can go on within the model's context window.
struct Compactor {
    let provider: any InferenceProvider
    let model: String
    let store: Store

    /// Characters of each tool result shown to the summarizer.
    static let toolResultCharacters = 2_000

    static let instructions = """
        You are compacting a conversation between a user and Kuri, an AI assistant, so it can continue \
        within a limited context. Write the summary that will replace the transcript you're given.

        Keep: what the user wants, especially the latest request that's still open; decisions and \
        preferences they stated; facts and results established, with names, numbers, paths and code \
        identifiers verbatim; tool calls that mattered and what they returned; the current state of any \
        plan; open questions. Drop pleasantries, repetition, and dead ends unless they explain a decision.

        Write compact notes in the third person ("The user asked…", "Kuri found…"), in the language of \
        the conversation. No preamble.
        """

    /// Summarizes `items[..<cut]` (with any earlier summary they contain)
    /// and stores the result. Returns the compaction item.
    func compact(_ items: [Item], keepingFrom cut: Int, conversationID: UUID, turnID: UUID?) async throws -> Item {
        precondition(cut > 0 && cut <= items.count)
        let transcript = Self.transcript(TurnRunner.history(from: Array(items[..<cut])))
        let request = InferenceRequest(
            model: model, instructions: Self.instructions,
            items: [.message(Message(role: .user, text: "Summarize this conversation:\n\n\(transcript)"))])

        var summary = ""
        var streamed = ""
        for try await event in provider.stream(request) {
            switch event {
            case .textDelta(let delta): streamed += delta
            case .itemCompleted(.message(let message)): summary += message.text
            default: break
            }
        }
        if summary.isEmpty { summary = streamed }
        summary = summary.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !summary.isEmpty else { throw KuriError.provider("The model returned an empty summary.") }

        let item = Item(conversationID: conversationID, turnID: turnID,
                        payload: .compaction(Compaction(summary: summary, throughItemID: items[cut - 1].id)))
        try await store.append(item)
        return item
    }

    /// Where to cut so that what's kept fits in `budget` tokens: from the
    /// latest user message if possible, so the current exchange stays
    /// verbatim; otherwise from the latest point that doesn't separate a
    /// tool call from its result. `nil` when there's nothing to summarize.
    static func cut(in items: [Item], budget: Int) -> Int? {
        let start = activeStart(in: items)
        guard let latestUser = items.lastIndex(where: {
            if case .message(let m) = $0.payload, m.role == .user { true } else { false }
        }) else { return nil }

        if ContextEstimate.tokens(items[latestUser...].map(\.payload)) <= budget {
            return latestUser > start ? latestUser : nil
        }
        // The current exchange alone is too big: keep only its tail.
        let lower = max(latestUser + 1, start + 1)
        if lower < items.count {
            for index in lower..<items.count {
                if case .toolResult = items[index].payload { continue }
                if ContextEstimate.tokens(items[index...].map(\.payload)) <= budget { return index }
            }
        }
        return latestUser > start ? latestUser : nil
    }

    /// The index of the first item not yet covered by a summary.
    static func activeStart(in items: [Item]) -> Int {
        guard let last = items.lastIndex(where: { if case .compaction = $0.payload { true } else { false } }),
              case .compaction(let compaction) = items[last].payload
        else { return 0 }
        if let through = compaction.throughItemID, let index = items.firstIndex(where: { $0.id == through }) {
            return index + 1
        }
        return last
    }

    /// Plain text for the summarizer: no tool-calling format to trip on.
    static func transcript(_ payloads: [Item.Payload]) -> String {
        payloads.compactMap { payload -> String? in
            switch payload {
            case .message(let message):
                return "\(message.role == .user ? "User" : "Kuri"): \(message.text)"
            case .toolCall(let call):
                return "Kuri called \(call.name) \(call.arguments)"
            case .toolResult(let result):
                let output = result.output.count > toolResultCharacters
                    ? result.output.prefix(toolResultCharacters) + " […]" : Substring(result.output)
                return "\(result.isError ? "Tool error" : "Tool result"): \(output)"
            case .compaction(let compaction):
                return "Summary of the conversation before this point:\n\(compaction.summary)"
            case .reasoning:
                return nil
            }
        }.joined(separator: "\n\n")
    }
}

/// A rough token count: about four characters per token. Good enough to
/// decide when to compact, with margin to spare.
enum ContextEstimate {
    static func tokens(_ payloads: [Item.Payload]) -> Int {
        payloads.reduce(0) { $0 + ((try? $1.encodedBody().count) ?? 0) } / 4
    }

    static func tokens(_ request: InferenceRequest) -> Int {
        let tools = request.tools.reduce(0) { $0 + $1.name.count + $1.description.count + $1.parameters.jsonString().count }
        return tokens(request.items) + (request.instructions.count + tools) / 4
    }
}
