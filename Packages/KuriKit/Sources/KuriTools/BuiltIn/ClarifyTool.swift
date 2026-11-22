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

    private struct Arguments: Decodable {
        let questions: [ClarifyRequest.Question]
    }

    public func run(arguments: Data, context: ToolContext) async throws -> ToolOutput {
        let questions = try decode(Arguments.self, from: arguments).questions
        guard !questions.isEmpty else { return .error("Provide at least one question.") }

        try await context.store.setTurnStatus(context.turnID, .awaitingInput)
        let answers = try await context.interaction.clarify(
            ClarifyRequest(conversationID: context.conversationID, callID: context.callID, questions: questions))
        try await context.store.setTurnStatus(context.turnID, .running)

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
