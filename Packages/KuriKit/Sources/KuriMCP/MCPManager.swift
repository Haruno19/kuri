import Foundation
import KuriConfig
import KuriCore
import KuriTools
import MCP

/// The state of one server declared in `mcp.json`, for the UI.
public struct MCPServerStatus: Sendable, Hashable, Identifiable {
    public enum State: Sendable, Hashable {
        case disabled
        case connecting
        case connected
        case failed(String)
    }

    public var name: String
    /// `stdio` or `http`.
    public var transport: String
    /// The command line or URL.
    public var target: String
    public var state: State
    /// "name version", as the server introduced itself.
    public var serverInfo: String?
    /// Tool names as the server calls them.
    public var tools: [String]
    /// The last lines of the server's log.
    public var log: [String]

    public var id: String { name }
}

/// Keeps the connections in line with `mcp.json` and the discovered tools
/// in the registry.
///
/// `apply` diffs the new configuration against the running one: new or
/// changed servers (re)connect, removed or disabled ones disconnect, and
/// untouched ones are left alone — so reloading the file is cheap.
public actor MCPManager {
    private struct Server {
        var config: MCPServerConfig
        var connection: MCPServerConnection?
        /// Bumped on every (re)start, so callbacks from an older
        /// connection are ignored.
        var generation: Int
        var status: MCPServerStatus
    }

    static let logLines = 50

    private let registry: ToolRegistry
    private let secrets: Secrets
    private let onChange: @Sendable ([MCPServerStatus]) -> Void
    private var servers: [String: Server] = [:]
    private var nextGeneration = 0

    public init(registry: ToolRegistry, secrets: Secrets = Secrets(),
                onChange: @escaping @Sendable ([MCPServerStatus]) -> Void = { _ in }) {
        self.registry = registry
        self.secrets = secrets
        self.onChange = onChange
    }

    public var statuses: [MCPServerStatus] {
        servers.values.map(\.status).sorted { $0.name < $1.name }
    }

    public func apply(_ config: MCPConfig) async {
        for name in servers.keys where config.mcpServers[name] == nil {
            await stop(name)
            servers[name] = nil
        }
        for (name, serverConfig) in config.mcpServers.sorted(by: { $0.key < $1.key }) {
            if servers[name]?.config == serverConfig { continue }
            await stop(name)
            start(name, config: serverConfig)
        }
        publish()
    }

    /// Restarts a server with its current configuration.
    public func reconnect(_ name: String) async {
        guard let config = servers[name]?.config else { return }
        await stop(name)
        start(name, config: config)
        publish()
    }

    public func shutdown() async {
        for name in servers.keys {
            await stop(name)
        }
        servers.removeAll()
        publish()
    }

    // MARK: Lifecycle

    private func start(_ name: String, config: MCPServerConfig) {
        nextGeneration += 1
        let generation = nextGeneration
        let transport = config.command != nil ? "stdio" : "http"
        let target = config.command.map { ([$0] + (config.args ?? [])).joined(separator: " ") }
            ?? config.url?.absoluteString ?? ""
        servers[name] = Server(
            config: config, connection: nil, generation: generation,
            status: MCPServerStatus(name: name, transport: transport, target: target,
                                    state: config.isEnabled ? .connecting : .disabled,
                                    serverInfo: nil, tools: [], log: []))
        guard config.isEnabled else { return }
        Task { await connect(name, generation: generation) }
    }

    private func connect(_ name: String, generation: Int) async {
        guard let server = servers[name], server.generation == generation else { return }
        let connection = MCPServerConnection(name: name)
        servers[name]?.connection = connection

        let handlers = MCPServerConnection.Handlers(
            log: { [weak self] line in Task { await self?.appendLog(line, to: name, generation: generation) } },
            exited: { [weak self] reason in Task { await self?.lost(name, generation: generation, reason: "Server \(reason).") } },
            toolsChanged: { [weak self] in Task { await self?.refreshTools(name, generation: generation) } })

        do {
            let info = try await connection.start(
                config: server.config,
                environment: try await environment(for: server.config),
                headers: try resolve(server.config.headers),
                handlers: handlers)
            guard isCurrent(name, generation) else {
                await connection.stop()
                return
            }
            servers[name]?.status.serverInfo = "\(info.serverInfo.name) \(info.serverInfo.version)"
            try await registerTools(name, generation: generation)
        } catch {
            await fail(name, generation: generation, message: error.localizedDescription)
        }
    }

    private func registerTools(_ name: String, generation: Int) async throws {
        guard let connection = servers[name]?.connection else { return }
        let tools = try await connection.listTools()
        guard isCurrent(name, generation) else { return }
        await registry.replace(
            source: .mcp(server: name),
            with: tools.map { (MCPTool(server: name, tool: $0, connection: connection), $0.name) })
        servers[name]?.status.tools = tools.map(\.name)
        servers[name]?.status.state = .connected
        publish()
    }

    private func refreshTools(_ name: String, generation: Int) async {
        guard isCurrent(name, generation) else { return }
        do {
            try await registerTools(name, generation: generation)
        } catch {
            await fail(name, generation: generation, message: error.localizedDescription)
        }
    }

    private func lost(_ name: String, generation: Int, reason: String) async {
        guard isCurrent(name, generation), servers[name]?.status.state != .disabled else { return }
        await fail(name, generation: generation, message: reason)
    }

    private func fail(_ name: String, generation: Int, message: String) async {
        guard isCurrent(name, generation) else { return }
        servers[name]?.status.state = .failed(message)
        servers[name]?.status.tools = []
        await registry.removeAll(from: .mcp(server: name))
        let connection = servers[name]?.connection
        servers[name]?.connection = nil
        publish()
        await connection?.stop()
    }

    private func stop(_ name: String) async {
        guard let server = servers[name] else { return }
        // Invalidate callbacks from the connection being stopped.
        nextGeneration += 1
        servers[name]?.generation = nextGeneration
        servers[name]?.connection = nil
        await registry.removeAll(from: .mcp(server: name))
        await server.connection?.stop()
    }

    private func appendLog(_ line: String, to name: String, generation: Int) {
        guard isCurrent(name, generation) else { return }
        servers[name]?.status.log.append(line)
        if let count = servers[name]?.status.log.count, count > Self.logLines {
            servers[name]?.status.log.removeFirst(count - Self.logLines)
        }
        publish()
    }

    private func isCurrent(_ name: String, _ generation: Int) -> Bool {
        servers[name]?.generation == generation
    }

    private func publish() {
        onChange(statuses)
    }

    // MARK: Environment

    /// Kuri's environment, with the login shell's PATH and the server's own
    /// variables on top.
    private func environment(for config: MCPServerConfig) async throws -> [String: String] {
        guard config.command != nil else { return [:] }
        var environment = ProcessInfo.processInfo.environment
        if let path = await LoginShell.path() { environment["PATH"] = path }
        for (key, value) in try resolve(config.env) { environment[key] = value }
        return environment
    }

    private func resolve(_ refs: [String: SecretRef]?) throws -> [String: String] {
        try (refs ?? [:]).mapValues { try secrets.resolve($0) }
    }
}

extension MCPConfig {
    /// Per-server tool policies, translated to the names the model sees.
    public var toolPolicies: [String: ToolPolicy] {
        var policies: [String: ToolPolicy] = [:]
        for (server, config) in mcpServers {
            for (pattern, policy) in config.tools ?? [:] {
                policies[ToolName.mcpPattern(server: server, pattern: pattern)] = policy
            }
        }
        return policies
    }
}
