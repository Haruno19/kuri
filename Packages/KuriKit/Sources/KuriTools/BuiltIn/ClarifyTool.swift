import Foundation
import KuriCore

/// Asks the user what the model can't find out by itself, and waits.
///
/// The answers are the tool's return value, not a new user message: the
/// model continues the same turn, and the transcript stays an ordinary
/// sequence of tool calls and results.
public struct ClarifyTool: Tool {
    public init() {}

    public let spec = ToolSpec(
        name: "clarify",
        description: """
            Ask the user one or more questions and wait for the answers. Use it when the request is \
            ambiguous in a way that would change the result and you can't resolve it yourself. Don't use \
            it for things you can find out with other tools. Offer likely answers as options when you can.
            """,
        parameters: [
            "type": "object",
            "properties": [
                "questions": [
                    "type": "array",
                    "minItems": 1,
                    "items": [
                        "type": "object",
                        "properties": [
                            "id": ["type": "string", "description": "Short identifier for the answer."],
                            "question": ["type": "string"],
                            "options": ["type": "array", "items": ["type": "string"]],
                        ],
                        "required": ["id", "question"],
                    ],
                ],
            ],
            "required": ["questions"],
        ])

    /// Lenient on purpose: small models often send the questions as a JSON
    /// string, options as objects, or no ids. The meaning is clear, so
    /// take it rather than bouncing the call.
    struct Arguments: Decodable {
        let questions: [ClarifyRequest.Question]

        private enum CodingKeys: String, CodingKey { case questions }

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            let lenient: [LenientQuestion]
            if let list = try? container.decode([LenientQuestion].self, forKey: .questions) {
                lenient = list
            } else if let text = try? container.decode(String.self, forKey: .questions) {
                lenient = try JSONDecoder().decode([LenientQuestion].self, from: Data(text.utf8))
            } else {
                lenient = try container.decode([LenientQuestion].self, forKey: .questions)
            }
            questions = lenient.enumerated().map { index, question in
                ClarifyRequest.Question(id: question.id ?? "q\(index + 1)", question: question.question,
                                        options: question.options)
            }
        }
    }

    private struct LenientQuestion: Decodable {
        let id: String?
        let question: String
        let options: [String]?

        private enum CodingKeys: String, CodingKey { case id, question, options }
        private struct Option: Decodable {
            let value: String
            private enum CodingKeys: String, CodingKey { case name, label, text, value, title }
            init(from decoder: any Decoder) throws {
                if let string = try? decoder.singleValueContainer().decode(String.self) {
                    value = string
                    return
                }
                let container = try decoder.container(keyedBy: CodingKeys.self)
                for key in [CodingKeys.label, .name, .text, .value, .title] {
                    if let string = try? container.decode(String.self, forKey: key) {
                        value = string
                        return
                    }
                }
                throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Options are strings."))
            }
        }

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            id = try? container.decode(String.self, forKey: .id)
            question = try container.decode(String.self, forKey: .question)
            options = (try? container.decode([Option].self, forKey: .options))?.map(\.value)
        }
    }

    public func run(arguments: Data, context: ToolContext) async throws -> ToolOutput {
        let questions = try decode(Arguments.self, from: arguments).questions
        guard !questions.isEmpty else { return .error("Provide at least one question.") }

        // The runner's interaction marks the turn as awaiting input meanwhile.
        let answers = try await context.interaction.clarify(
            ClarifyRequest(conversationID: context.conversationID, callID: context.callID, questions: questions))

        let lines = questions.map { question in
            "\(question.question)\n→ \(answers[question.id]?.nilIfBlank ?? "(no answer)")"
        }
        return ToolOutput(lines.joined(separator: "\n\n"))
    }
}

extension String {
    var nilIfBlank: String? {
        trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : self
    }
}
