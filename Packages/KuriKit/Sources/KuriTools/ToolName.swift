/// Names as the model sees them.
///
/// Providers restrict function names; the strictest common rule is
/// `[A-Za-z0-9_-]{1,64}`, so every name Kuri hands out satisfies it.
public enum ToolName {
    public static let maxLength = 64
    public static let separator = "__"

    /// `<server>__<tool>`, for a tool discovered on an MCP server.
    public static func mcp(server: String, tool: String) -> String {
        String((sanitize(server) + separator + sanitize(tool)).prefix(maxLength))
    }

    /// Like `mcp(server:tool:)`, but keeps `*` so policy globs written
    /// against the server's own names still match.
    public static func mcpPattern(server: String, pattern: String) -> String {
        sanitize(server) + separator + sanitize(pattern, keeping: "*")
    }

    /// The server part of an MCP tool name, if it is one.
    public static func server(of name: String) -> String? {
        name.range(of: separator).map { String(name[..<$0.lowerBound]) }
    }

    static func sanitize(_ string: String, keeping extra: Character? = nil) -> String {
        let mapped = string.map { character -> Character in
            if character == extra { return character }
            let allowed = character.isASCII && (character.isLetter || character.isNumber || character == "_" || character == "-")
            return allowed ? character : "_"
        }
        return mapped.isEmpty ? "_" : String(mapped)
    }
}
