import Foundation
import KuriCore
import KuriInference

/// Writes a short title for a conversation from its first exchange.
struct TitleGenerator {
    let provider: any InferenceProvider
    let model: String

    /// Characters of each side of the exchange shown to the model.
    static let excerptCharacters = 1_500
    static let maxCharacters = 60

    static let instructions = """
        Write a title for this conversation: 2 to 6 words, in the conversation's language, \
        no quotes, no trailing punctuation. Reply with the title only.
        """

    func title(question: String, answer: String) async throws -> String? {
        let excerpt = """
            User: \(question.prefix(Self.excerptCharacters))

            Assistant: \(answer.prefix(Self.excerptCharacters))
            """
        // No output cap: reasoning models spend tokens thinking before the
        // title, and a tight cap leaves them with nothing to say.
        let request = InferenceRequest(model: model, instructions: Self.instructions,
                                       items: [.message(Message(role: .user, text: excerpt))])
        var text = ""
        var streamed = ""
        for try await event in provider.stream(request) {
            switch event {
            case .textDelta(let delta): streamed += delta
            case .itemCompleted(.message(let message)): text += message.text
            default: break
            }
        }
        return Self.clean(text.isEmpty ? streamed : text)
    }

    /// Models dress titles up: labels, quotes, markdown, a final period.
    static func clean(_ raw: String) -> String? {
        var title = raw.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        title = title.trimmingCharacters(in: .whitespaces)
        for label in ["title:", "titolo:", "titre:", "título:"] where title.lowercased().hasPrefix(label) {
            title = String(title.dropFirst(label.count))
        }
        title = title.trimmingCharacters(in: CharacterSet(charactersIn: " \"'`*_#“”‘’«»"))
        while let last = title.last, ".!,;:".contains(last) { title.removeLast() }
        title = title.trimmingCharacters(in: .whitespaces)
        guard !title.isEmpty else { return nil }
        return title.count > maxCharacters ? String(title.prefix(maxCharacters - 1)) + "…" : title
    }
}
