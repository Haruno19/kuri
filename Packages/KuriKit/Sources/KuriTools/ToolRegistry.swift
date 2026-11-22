import Darwin
import KuriCore

/// The tools available to the model, and the policies that gate them.
///
/// Built-in tools are registered once; MCP tools come and go as servers
/// connect and disconnect, which is why this is an actor.
public actor ToolRegistry {
    private var tools: [String: any Tool] = [:]
    /// Name or `*` glob → policy, from config files or the user.
    private var policies: [String: ToolPolicy] = [:]

    public init(_ tools: [any Tool] = []) {
        for tool in tools { self.tools[tool.spec.name] = tool }
    }

    public func register(_ tool: any Tool) {
        tools[tool.spec.name] = tool
    }

    /// Removes every tool whose name starts with `prefix` (e.g. `"github__"`).
    public func unregister(prefix: String) {
        tools = tools.filter { !$0.key.hasPrefix(prefix) }
    }

    public func setPolicies(_ policies: [String: ToolPolicy]) {
        self.policies = policies
    }

    public func tool(named name: String) -> (any Tool)? {
        tools[name]
    }

    /// Specs for every tool the model may see, in a stable order.
    /// Denied tools are left out entirely.
    public func specs() -> [ToolSpec] {
        tools.values
            .filter { policy(for: $0) != .deny }
            .map(\.spec)
            .sorted { $0.name < $1.name }
    }

    /// An exact name wins over globs; among globs, the longest pattern wins.
    public func policy(for tool: any Tool) -> ToolPolicy {
        let name = tool.spec.name
        if let exact = policies[name] { return exact }
        let match = policies
            .filter { $0.key.contains("*") && fnmatch($0.key, name, 0) == 0 }
            .max { $0.key.count < $1.key.count }
        return match?.value ?? tool.defaultPolicy
    }
}
