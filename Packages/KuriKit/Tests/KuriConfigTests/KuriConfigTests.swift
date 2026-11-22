import Foundation
import KuriCore
import Testing
@testable import KuriConfig

@Suite struct ConfigTests {
    @Test func decodesJSON5WithCommentsAndShorthandModels() throws {
        let json5 = """
            // a comment
            {
              defaultModel: "ollama/qwen3:8b",
              providers: {
                ollama: {
                  format: "open-responses",
                  baseURL: "http://localhost:11434/v1",
                  models: ["qwen3:8b", { id: "qwen3-coder:30b", contextWindow: 65536 }],
                },
                anthropic: { format: "anthropic-messages", apiKey: "keychain:anthropic", },
              },
            }
            """
        let config = try ConfigLoader.decode(Config.self, from: Data(json5.utf8))
        #expect(config.defaultModel == ModelRef(provider: "ollama", model: "qwen3:8b"))
        #expect(config.providers["ollama"]?.models?.map(\.id) == ["qwen3:8b", "qwen3-coder:30b"])
        #expect(config.modelConfig(for: ModelRef(provider: "ollama", model: "qwen3-coder:30b"))?.contextWindow == 65536)
        #expect(config.providers["anthropic"]?.apiKey == .keychain("anthropic"))
        #expect(config.declaredModels.map(\.description) == ["ollama/qwen3:8b", "ollama/qwen3-coder:30b"])
    }

    @Test func templatesDecode() throws {
        let config = try ConfigLoader.decode(Config.self, from: Data(ConfigLoader.configTemplate.utf8))
        #expect(config.defaultModel != nil)
        #expect(config.providers["ollama"]?.format == .openResponses)
        let mcp = try ConfigLoader.decode(MCPConfig.self, from: Data(ConfigLoader.mcpTemplate.utf8))
        #expect(mcp.mcpServers.isEmpty)
    }

    @Test func decodesMCPServers() throws {
        let json5 = """
            { mcpServers: {
                notes: { command: "uvx", args: ["notes-mcp"], enabled: false },
                remote: { url: "https://example.com/mcp", tools: { "delete_*": "deny", "*": "allow" } },
            } }
            """
        let mcp = try ConfigLoader.decode(MCPConfig.self, from: Data(json5.utf8))
        #expect(mcp.mcpServers["notes"]?.isEnabled == false)
        #expect(mcp.mcpServers["remote"]?.tools?["delete_*"] == .deny)
    }

    @Test func writesTemplatesOnFirstLoad() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "kuri-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let loader = ConfigLoader(home: KuriHome(root: root))
        _ = try loader.loadConfig()
        _ = try loader.loadMCP()
        #expect(FileManager.default.fileExists(atPath: root.appending(path: "config.json").path))
        #expect(FileManager.default.fileExists(atPath: root.appending(path: "mcp.json").path))
    }

    @Test func reportsWhereConfigIsInvalid() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "kuri-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let home = KuriHome(root: root)
        try home.prepare()
        try Data(#"{ providers: { x: { format: "carrier-pigeon" } } }"#.utf8).write(to: home.configFile)
        #expect(throws: KuriError.self) { try ConfigLoader(home: home).loadConfig() }
    }
}

@Suite struct SecretTests {
    @Test func parsesReferences() {
        #expect(SecretRef("keychain:openai") == .keychain("openai"))
        #expect(SecretRef("env:OPENAI_API_KEY") == .environment("OPENAI_API_KEY"))
        #expect(SecretRef("sk-123") == .literal("sk-123"))
    }

    @Test func resolvesEnvironmentAndLiterals() throws {
        let secrets = Secrets(environment: ["KEY": "value"])
        #expect(try secrets.resolve(.environment("KEY")) == "value")
        #expect(try secrets.resolve(.literal("x")) == "x")
        #expect(throws: KuriError.self) { try secrets.resolve(.environment("MISSING")) }
    }

    @Test func homeResolutionOrder() {
        #expect(KuriHome.resolve(environment: ["KURI_HOME": "/tmp/kuri-home", "XDG_CONFIG_HOME": "/tmp/xdg"])
            .database.path == "/tmp/kuri-home/kuri.sqlite")
        #expect(KuriHome.resolve(environment: ["XDG_CONFIG_HOME": "/tmp/xdg"]).root.path == "/tmp/xdg/kuri")
        #expect(KuriHome.resolve(environment: [:]).root.path.hasSuffix("/.config/kuri"))
    }
}

@Suite struct ConfigEditorTests {
    private func home(with text: String) throws -> KuriHome {
        let root = FileManager.default.temporaryDirectory.appending(path: "kuri-edit-\(UUID().uuidString)")
        let home = KuriHome(root: root)
        try home.prepare()
        try Data(text.utf8).write(to: home.configFile)
        return home
    }

    @Test func registersModelsAndKeepsUnknownKeys() throws {
        let home = try home(with: """
            // a comment that will be dropped
            {
              defaultModel: "ollama/a",
              someFutureKey: { nested: true },
              providers: { ollama: { format: "open-responses", baseURL: "http://localhost:11434/v1", models: ["a"], custom: 1 } },
            }
            """)
        defer { try? FileManager.default.removeItem(at: home.root) }
        let editor = ConfigEditor(home: home)

        try editor.register(ModelConfig(id: "b", contextWindow: 32768), provider: "ollama")
        try editor.register(ModelConfig(id: "a", reasoningEffort: "high"), provider: "ollama")  // replaces
        try editor.unregister(model: "missing", provider: "ollama")
        try editor.setDefaultModel(ModelRef("ollama/b"))

        let text = try String(contentsOf: home.configFile, encoding: .utf8)
        let config = try ConfigLoader.decode(Config.self, from: Data(text.utf8))
        #expect(config.defaultModel == ModelRef("ollama/b"))
        #expect(config.providers["ollama"]?.models == [ModelConfig(id: "a", reasoningEffort: "high"),
                                                       ModelConfig(id: "b", contextWindow: 32768)])
        #expect(text.contains("someFutureKey: { nested: true },"))
        #expect(text.contains("custom: 1,"))
        #expect(!text.contains("a comment that will be dropped"))
        #expect(text.hasPrefix("// Kuri configuration."))

        try editor.unregister(model: "a", provider: "ollama")
        #expect(try ConfigLoader(home: home).loadConfig().providers["ollama"]?.models?.map(\.id) == ["b"])
    }

    @Test func refusesUnknownProviders() throws {
        let home = try home(with: #"{ providers: {} }"#)
        defer { try? FileManager.default.removeItem(at: home.root) }
        #expect(throws: KuriError.self) { try ConfigEditor(home: home).register(ModelConfig(id: "x"), provider: "nope") }
    }

    @Test func writesReadableJSON5() throws {
        let value: JSONValue = [
            "providers": ["ollama": ["models": ["a", ["id": "b", "contextWindow": 65536]], "format": "open-responses"]],
            "defaultModel": "ollama/a",
            "weird key": 1.5,
        ]
        #expect(JSON5Writer.write(value) == """
            {
              defaultModel: "ollama/a",
              providers: {
                ollama: {
                  format: "open-responses",
                  models: ["a", { id: "b", contextWindow: 65536 }],
                },
              },
              "weird key": 1.5,
            }

            """)
    }
}
