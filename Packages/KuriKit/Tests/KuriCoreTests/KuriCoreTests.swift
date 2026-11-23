import Foundation
import Testing
@testable import KuriCore

@Suite struct ModelRefTests {
    @Test func splitsAtFirstSlash() throws {
        let ref = try #require(ModelRef("openrouter/meta/llama-4"))
        #expect(ref.provider == "openrouter")
        #expect(ref.model == "meta/llama-4")
        #expect(ref.description == "openrouter/meta/llama-4")
    }

    @Test(arguments: ["", "ollama", "/qwen3", "ollama/"])
    func rejectsMalformed(_ string: String) {
        #expect(ModelRef(string) == nil)
    }
}

@Suite struct ItemTests {
    @Test func payloadRoundTripsThroughKindAndBody() throws {
        let payloads: [Item.Payload] = [
            .message(Message(role: .user, text: "Look at this")),
            .reasoning(Reasoning(text: "thinking", opaque: "xyz", provider: "openai")),
            .toolCall(ToolCall(id: "call_1", name: "tasklist", arguments: #"{"tasks":[]}"#)),
            .toolResult(ToolResult(callID: "call_1", output: "ok", isError: false)),
            .compaction(Compaction(summary: "Earlier we discussed…")),
        ]
        for payload in payloads {
            let decoded = try Item.Payload(kind: payload.kind, body: payload.encodedBody())
            #expect(decoded == payload)
        }
    }

    @Test func messageIsStoredAsContentParts() throws {
        let body = try Item.Payload.message(Message(role: .user, text: "hi")).encodedBody()
        #expect(String(decoding: body, as: UTF8.self) == #"{"content":[{"text":"hi","type":"text"}],"role":"user"}"#)
        let stored = #"{"content":[{"text":"a","type":"text"},{"text":"b","type":"text"}],"role":"assistant"}"#
        #expect(try Item.Payload(kind: "message", body: Data(stored.utf8)) == .message(Message(role: .assistant, text: "ab")))
    }
}

@Suite struct JSONValueTests {
    @Test func roundTrips() throws {
        let value: JSONValue = ["type": "object", "required": ["a"], "n": 1.5, "flag": true, "none": nil]
        let data = try JSONEncoder().encode(value)
        #expect(try JSONDecoder().decode(JSONValue.self, from: data) == value)
    }

    @Test func jsonStringIsStable() {
        let a: JSONValue = ["b": 1, "a": 2]
        let b: JSONValue = ["a": 2, "b": 1]
        #expect(a.jsonString() == b.jsonString())
    }
}
