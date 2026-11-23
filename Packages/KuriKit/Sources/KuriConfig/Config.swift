import Foundation
import KuriCore

/// The app's colour scheme.
public enum Appearance: String, Codable, Sendable, Hashable, CaseIterable {
    case system, light, dark
}

/// The contents of `config.json`.
public struct Config: Codable, Sendable, Hashable {
    /// The model new conversations start with.
    public var defaultModel: ModelRef?
    /// A small, fast model for background jobs: titles, summaries, memory review.
    public var utilityModel: ModelRef?
    public var providers: [String: ProviderConfig]
    /// Tool name or `*` glob → policy, for any tool by the name the model
    /// sees (`memory`, `github__create_issue`). Wins over `mcp.json`.
    public var tools: [String: ToolPolicy]?
    public var sandbox: SandboxConfig?
    /// Name conversations after their first exchange. Default `true`.
    public var generateTitles: Bool?
    /// Light, dark, or following the system (the default).
    public var appearance: Appearance?

    public init(
        defaultModel: ModelRef? = nil,
        utilityModel: ModelRef? = nil,
        providers: [String: ProviderConfig] = [:],
        tools: [String: ToolPolicy]? = nil,
        sandbox: SandboxConfig? = nil,
        generateTitles: Bool? = nil,
        appearance: Appearance? = nil
    ) {
        self.defaultModel = defaultModel
        self.utilityModel = utilityModel
        self.providers = providers
        self.tools = tools
        self.sandbox = sandbox
        self.generateTitles = generateTitles
        self.appearance = appearance
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        defaultModel = try container.decodeIfPresent(ModelRef.self, forKey: .defaultModel)
        utilityModel = try container.decodeIfPresent(ModelRef.self, forKey: .utilityModel)
        providers = try container.decodeIfPresent([String: ProviderConfig].self, forKey: .providers) ?? [:]
        tools = try container.decodeIfPresent([String: ToolPolicy].self, forKey: .tools)
        sandbox = try container.decodeIfPresent(SandboxConfig.self, forKey: .sandbox)
        generateTitles = try container.decodeIfPresent(Bool.self, forKey: .generateTitles)
        appearance = try container.decodeIfPresent(Appearance.self, forKey: .appearance)
    }

    /// Every model declared in the file, in a stable order.
    public var declaredModels: [ModelRef] {
        providers.keys.sorted().flatMap { name in
            (providers[name]?.models ?? []).map { ModelRef(provider: name, model: $0.id) }
        }
    }

    public func modelConfig(for ref: ModelRef) -> ModelConfig? {
        providers[ref.provider]?.models?.first { $0.id == ref.model }
    }

    /// The model's context window: as declared, or the format's own when
    /// it's fixed (Apple's on-device model).
    public func contextWindow(for ref: ModelRef) -> Int? {
        modelConfig(for: ref)?.contextWindow ?? providers[ref.provider]?.format.fixedContextWindow
    }
}

/// The wire format a provider speaks. Picks the adapter.
public enum WireFormat: String, Codable, Sendable, Hashable, CaseIterable {
    case openResponses = "open-responses"
    case anthropicMessages = "anthropic-messages"
    case gemini = "gemini"
    case chatCompletions = "chat-completions"
    case appleFoundationModels = "apple-foundation-models"

    /// Formats whose single model has a known, fixed context window.
    public var fixedContextWindow: Int? {
        self == .appleFoundationModels ? 4_096 : nil
    }
}

public struct ProviderConfig: Codable, Sendable, Hashable {
    public var format: WireFormat
    public var baseURL: URL?
    public var apiKey: SecretRef?
    /// Extra HTTP headers. Values may be secret references.
    public var headers: [String: SecretRef]?
    public var models: [ModelConfig]?
    /// Ask the provider for its model list instead of (or on top of) `models`.
    public var discoverModels: Bool?

    public init(
        format: WireFormat,
        baseURL: URL? = nil,
        apiKey: SecretRef? = nil,
        headers: [String: SecretRef]? = nil,
        models: [ModelConfig]? = nil,
        discoverModels: Bool? = nil
    ) {
        self.format = format
        self.baseURL = baseURL
        self.apiKey = apiKey
        self.headers = headers
        self.models = models
        self.discoverModels = discoverModels
    }
}

/// A model entry. In the file, either a bare id string or an object.
public struct ModelConfig: Codable, Sendable, Hashable {
    public var id: String
    public var name: String?
    public var contextWindow: Int?
    public var maxOutputTokens: Int?
    public var reasoningEffort: String?
    /// Models to try, in order, when this one fails.
    public var fallbacks: [ModelRef]?

    public init(id: String, name: String? = nil, contextWindow: Int? = nil, maxOutputTokens: Int? = nil,
                reasoningEffort: String? = nil, fallbacks: [ModelRef]? = nil) {
        self.id = id
        self.name = name
        self.contextWindow = contextWindow
        self.maxOutputTokens = maxOutputTokens
        self.reasoningEffort = reasoningEffort
        self.fallbacks = fallbacks
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, contextWindow, maxOutputTokens, reasoningEffort, fallbacks
    }

    public init(from decoder: any Decoder) throws {
        if let id = try? decoder.singleValueContainer().decode(String.self) {
            self.init(id: id)
            return
        }
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: try container.decode(String.self, forKey: .id),
            name: try container.decodeIfPresent(String.self, forKey: .name),
            contextWindow: try container.decodeIfPresent(Int.self, forKey: .contextWindow),
            maxOutputTokens: try container.decodeIfPresent(Int.self, forKey: .maxOutputTokens),
            reasoningEffort: try container.decodeIfPresent(String.self, forKey: .reasoningEffort),
            fallbacks: try container.decodeIfPresent([ModelRef].self, forKey: .fallbacks))
    }
}

public struct SandboxConfig: Codable, Sendable, Hashable {
    /// OCI image reference for conversation containers.
    public var image: String?
    public var cpus: Int?
    public var memoryMiB: Int?
    /// Minutes of inactivity before a conversation's container is stopped.
    public var idleMinutes: Int?
    /// A Linux kernel (`vmlinux`) already on disk, instead of downloading one.
    public var kernel: String?
    /// A Kata Containers release tarball to take the kernel from.
    public var kernelURL: URL?

    public init(image: String? = nil, cpus: Int? = nil, memoryMiB: Int? = nil, idleMinutes: Int? = nil,
                kernel: String? = nil, kernelURL: URL? = nil) {
        self.image = image
        self.cpus = cpus
        self.memoryMiB = memoryMiB
        self.idleMinutes = idleMinutes
        self.kernel = kernel
        self.kernelURL = kernelURL
    }
}

/// The contents of `mcp.json`. Same `mcpServers` shape as other MCP clients.
public struct MCPConfig: Codable, Sendable, Hashable {
    public var mcpServers: [String: MCPServerConfig]

    public init(mcpServers: [String: MCPServerConfig] = [:]) {
        self.mcpServers = mcpServers
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        mcpServers = try container.decodeIfPresent([String: MCPServerConfig].self, forKey: .mcpServers) ?? [:]
    }
}

public struct MCPServerConfig: Codable, Sendable, Hashable {
    // stdio transport
    public var command: String?
    public var args: [String]?
    public var env: [String: SecretRef]?
    // Streamable HTTP transport
    public var url: URL?
    public var headers: [String: SecretRef]?
    // Kuri extensions
    public var enabled: Bool?
    /// Tool name (as the server calls it) or `*` glob → policy. Unlisted
    /// tools run without asking if the server marks them read-only, and
    /// ask otherwise.
    public var tools: [String: ToolPolicy]?

    public var isEnabled: Bool { enabled ?? true }

    public init(command: String? = nil, args: [String]? = nil, env: [String: SecretRef]? = nil,
                url: URL? = nil, headers: [String: SecretRef]? = nil,
                enabled: Bool? = nil, tools: [String: ToolPolicy]? = nil) {
        self.command = command
        self.args = args
        self.env = env
        self.url = url
        self.headers = headers
        self.enabled = enabled
        self.tools = tools
    }
}
