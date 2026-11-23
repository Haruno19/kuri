import Foundation
import KuriCore

/// Reads `config.json` and `mcp.json`, writing commented templates when
/// they don't exist yet.
public struct ConfigLoader: Sendable {
    public let home: KuriHome

    public init(home: KuriHome) {
        self.home = home
    }

    public func loadConfig() throws -> Config {
        try load(Config.self, from: home.configFile, template: Self.configTemplate)
    }

    public func loadMCP() throws -> MCPConfig {
        try load(MCPConfig.self, from: home.mcpFile, template: Self.mcpTemplate)
    }

    /// Decodes a JSON5 document. Exposed for tests and for validating edits.
    public static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        let decoder = JSONDecoder()
        decoder.allowsJSON5 = true
        return try decoder.decode(type, from: data)
    }

    private func load<T: Decodable>(_ type: T.Type, from url: URL, template: String) throws -> T {
        if !FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) {
            try home.prepare()
            try Data(template.utf8).write(to: url, options: .atomic)
        }
        let data = try Data(contentsOf: url)
        do {
            return try Self.decode(type, from: data)
        } catch let error as DecodingError {
            throw KuriError.invalidConfig(file: url.lastPathComponent, reason: Self.describe(error))
        }
    }

    private static func describe(_ error: DecodingError) -> String {
        func path(_ context: DecodingError.Context) -> String {
            let keys = context.codingPath.map(\.stringValue).joined(separator: ".")
            return keys.isEmpty ? "" : " at \(keys)"
        }
        return switch error {
        case .dataCorrupted(let context): "\(context.debugDescription)\(path(context))"
        case .keyNotFound(let key, let context): "missing “\(key.stringValue)”\(path(context))"
        case .typeMismatch(_, let context), .valueNotFound(_, let context): "\(context.debugDescription)\(path(context))"
        @unknown default: error.localizedDescription
        }
    }

    static let configTemplate = """
        // Kuri configuration. JSON5: comments, unquoted keys and trailing commas are fine.
        // Kuri reloads this file when it changes.
        {
          // "<provider>/<model>". Everything after the first slash is the model id.
          defaultModel: "ollama/qwen3.5:2b",

          // Name conversations after their first exchange, with utilityModel if set
          // (otherwise the conversation's own model). Settings › General toggles it.
          generateTitles: true,

          // "system" (the default), "light" or "dark".
          appearance: "system",

          // Launch with only the menu bar icon, no main window.
          startInBackground: false,

          providers: {
            // Anything that speaks Open Responses: Ollama, LM Studio, vLLM, OpenAI…
            ollama: {
              format: "open-responses",
              baseURL: "http://localhost:11434/v1",
              models: ["qwen3.5:2b"],
            },

            // lmstudio: {
            //   format: "open-responses",
            //   baseURL: "http://localhost:1234/v1",
            //   discoverModels: true,
            // },

            // Apple's on-device model: offline and free, text only (no tools), a 4,096-token context.
            // A good utilityModel: utilityModel: "apple/default".
            // apple: { format: "apple-foundation-models", models: ["default"] },

            // Secrets are references: "keychain:<name>" or "env:<VAR>".
            // openai: {
            //   format: "open-responses",
            //   baseURL: "https://api.openai.com/v1",
            //   apiKey: "keychain:openai",
            //   models: [{ id: "gpt-5", reasoningEffort: "medium" }],
            // },

            // Anthropic's API (baseURL defaults to it). Ollama speaks this format too.
            // anthropic: {
            //   format: "anthropic-messages",
            //   apiKey: "keychain:anthropic",
            //   models: [{ id: "claude-sonnet-5-5", reasoningEffort: "medium", contextWindow: 1000000 }],
            // },
          },

          // Tool policies: "allow", "ask" or "deny", by the name the model sees.
          // "*" globs work; MCP tools are named "<server>__<tool>".
          // tools: { memory: "deny", "github__*": "ask" },

          // The Linux sandbox behind the shell tool (set it up in Settings › Sandbox).
          // sandbox: { image: "docker.io/library/python:3-slim", cpus: 4, memoryMiB: 2048, idleMinutes: 10 },
        }

        """

    static let mcpTemplate = """
        // MCP servers. Same "mcpServers" shape as other MCP clients, plus two Kuri keys:
        //   enabled: false            keep a server declared but disconnected
        //   tools: { "name": "allow" | "ask" | "deny" }   per-tool policy, "*" globs allowed
        {
          mcpServers: {
            // example: { command: "uvx", args: ["some-mcp-server"] },
            // remote:  { url: "https://example.com/mcp", headers: { Authorization: "keychain:remote-mcp" } },
          },
        }

        """
}
