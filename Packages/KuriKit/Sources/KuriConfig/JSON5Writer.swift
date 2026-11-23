import Foundation
import KuriCore

/// Writes a `JSONValue` as JSON5 that reads like a hand-written file:
/// unquoted keys, trailing commas, two-space indents, short arrays and
/// objects on one line, and a stable key order (known keys first, in the
/// order the README documents them, then the rest alphabetically).
enum JSON5Writer {
    static let keyOrder = [
        // config.json
        "defaultModel", "utilityModel", "generateTitles", "appearance", "startInBackground", "inspectorLayout", "providers", "tools", "sandbox",
        "format", "baseURL", "apiKey", "headers", "discoverModels", "models",
        "id", "name", "contextWindow", "maxOutputTokens", "reasoningEffort", "fallbacks",
        // mcp.json
        "mcpServers", "command", "args", "env", "url", "enabled",
    ]

    static let inlineLimit = 72

    static func write(_ value: JSONValue, header: String? = nil) -> String {
        var output = header.map { $0.split(separator: "\n", omittingEmptySubsequences: false).map { "// \($0)" }.joined(separator: "\n") + "\n" } ?? ""
        output += render(value, indent: 0)
        return output + "\n"
    }

    private static func render(_ value: JSONValue, indent: Int) -> String {
        switch value {
        case .null: return "null"
        case .bool(let bool): return bool ? "true" : "false"
        case .number(let number): return format(number)
        case .string(let string): return quote(string)
        case .array(let items):
            if items.isEmpty { return "[]" }
            let inline = "[" + items.map { render($0, indent: indent + 1) }.joined(separator: ", ") + "]"
            if !inline.contains("\n"), inline.count + indent <= inlineLimit { return inline }
            let pad = String(repeating: "  ", count: indent + 1)
            let lines = items.map { pad + render($0, indent: indent + 1) + "," }
            return "[\n" + lines.joined(separator: "\n") + "\n" + String(repeating: "  ", count: indent) + "]"
        case .object(let object):
            if object.isEmpty { return "{}" }
            let keys = sortedKeys(object.keys)
            // Leaf objects (no nested containers) may go on one line.
            let isLeaf = object.values.allSatisfy { if case .object = $0 { false } else if case .array = $0 { false } else { true } }
            if isLeaf && indent > 0 {
                let inline = "{ " + keys.map { "\(key($0)): \(render(object[$0]!, indent: 0))" }.joined(separator: ", ") + " }"
                if inline.count + indent * 2 <= inlineLimit { return inline }
            }
            let pad = String(repeating: "  ", count: indent + 1)
            let lines = keys.map { pad + "\(key($0)): " + render(object[$0]!, indent: indent + 1) + "," }
            return "{\n" + lines.joined(separator: "\n") + "\n" + String(repeating: "  ", count: indent) + "}"
        }
    }

    static func sortedKeys(_ keys: Dictionary<String, JSONValue>.Keys) -> [String] {
        keys.sorted { a, b in
            switch (keyOrder.firstIndex(of: a), keyOrder.firstIndex(of: b)) {
            case let (i?, j?): i < j
            case (_?, nil): true
            case (nil, _?): false
            case (nil, nil): a < b
            }
        }
    }

    private static func key(_ key: String) -> String {
        let identifier = key.first.map { $0.isLetter || $0 == "_" || $0 == "$" } == true
            && key.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_" || $0 == "$") }
        return identifier ? key : quote(key)
    }

    private static func quote(_ string: String) -> String {
        let data = (try? JSONEncoder().encode(string)) ?? Data("\"\"".utf8)
        return String(decoding: data, as: UTF8.self).replacingOccurrences(of: "\\/", with: "/")
    }

    private static func format(_ number: Double) -> String {
        if number.rounded() == number, abs(number) < 1e15 { return String(Int64(number)) }
        return String(number)
    }
}
