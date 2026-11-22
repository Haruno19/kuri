import Darwin
import KuriCore

/// Where a tool comes from.
public enum ToolSource: Sendable, Hashable {
    /// Implemented by Kuri itself.
    case builtIn
    /// Discovered on an MCP server, by its name in `mcp.json`.
    case mcp(server: String)
}

/// A tool as the settings UI shows it.
public struct ToolInfo: Sendable, Hashable, Identifiable {
    /// The name the model sees (`clarify`, `github__create_issue`).
    public var name: String
    /// The name at the source (`create_issue`).
    public var originalName: String
    public var description: String
    public var source: ToolSource
    public var policy: ToolPolicy

    public var id: String { name }
}

/// The tools available to the model, and the policies that gate them.
///
/// Built-in tools are registered once; MCP tools come and go as servers
/// connect and disconnect, which is why this is an actor.
public actor ToolRegistry {
    private struct Entry {
        let tool: any Tool
        let source: ToolSource
        let originalName: String
    }

    private var entries: [String: Entry] = [:]
    /// Name or `*` glob → policy, from config files.
    private var policies: [String: ToolPolicy] = [:]
    private var observers: [@Sendable () -> Void] = []

    public init(_ builtIns: [any Tool] = []) {
        for tool in builtIns {
            entries[tool.spec.name] = Entry(tool: tool, source: .builtIn, originalName: tool.spec.name)
        }
    }

    /// Called after every change to the set of tools or their policies.
    public func onChange(_ observer: @escaping @Sendable () -> Void) {
        observers.append(observer)
    }

    public func register(_ tool: any Tool, source: ToolSource, originalName: String? = nil) {
        entries[tool.spec.name] = Entry(tool: tool, source: source, originalName: originalName ?? tool.spec.name)
        notify()
    }

    /// Replaces every tool of `source` with `tools` (pairs of tool and its
    /// name at the source).
    public func replace(source: ToolSource, with tools: [(tool: any Tool, originalName: String)]) {
        entries = entries.filter { $0.value.source != source }
        for (tool, originalName) in tools {
            entries[tool.spec.name] = Entry(tool: tool, source: source, originalName: originalName)
        }
        notify()
    }

    public func removeAll(from source: ToolSource) {
        replace(source: source, with: [])
    }

    public func setPolicies(_ policies: [String: ToolPolicy]) {
        guard policies != self.policies else { return }
        self.policies = policies
        notify()
    }

    public func tool(named name: String) -> (any Tool)? {
        entries[name]?.tool
    }

    /// Specs for every tool the model may see, in a stable order.
    /// Denied tools are left out entirely.
    public func specs() -> [ToolSpec] {
        entries.values
            .filter { policy(for: $0.tool) != .deny }
            .map(\.tool.spec)
            .sorted { $0.name < $1.name }
    }

    public func catalog() -> [ToolInfo] {
        entries.values
            .map { ToolInfo(name: $0.tool.spec.name, originalName: $0.originalName,
                            description: $0.tool.spec.description, source: $0.source, policy: policy(for: $0.tool)) }
            .sorted { $0.name < $1.name }
    }

    /// An exact name wins over globs; among globs, the longest pattern wins.
    public func policy(for tool: any Tool) -> ToolPolicy {
        Self.resolve(tool.spec.name, in: policies) ?? tool.defaultPolicy
    }

    static func resolve(_ name: String, in policies: [String: ToolPolicy]) -> ToolPolicy? {
        if let exact = policies[name] { return exact }
        return policies
            .filter { $0.key.contains("*") && fnmatch($0.key, name, 0) == 0 }
            .max { $0.key.count < $1.key.count }?
            .value
    }

    private func notify() {
        for observer in observers { observer() }
    }
}
