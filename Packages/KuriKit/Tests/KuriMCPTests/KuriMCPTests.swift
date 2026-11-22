import Foundation
import KuriConfig
import KuriCore
import KuriStore
import KuriTools
import MCP
import Synchronization
import Testing
@testable import KuriMCP

private let fixtures = Bundle.module.resourceURL!.appending(path: "Fixtures")

private struct NoInteraction: UserInteraction {
    func clarify(_ request: ClarifyRequest) async throws -> [String: String] { [:] }
    func approve(_ request: ApprovalRequest) async throws -> Bool { true }
}

/// Polls until `condition` holds, failing after `timeout`.
private func eventually(_ what: Comment, timeout: Duration = .seconds(15),
                        _ condition: () async -> Bool) async throws {
    let deadline = ContinuousClock.now + timeout
    while !(await condition()) {
        guard ContinuousClock.now < deadline else {
            Issue.record("Timed out waiting: \(what)")
            throw CancellationError()
        }
        try await Task.sleep(for: .milliseconds(50))
    }
}

private func stdioConfig(enabled: Bool? = nil, tools: [String: ToolPolicy]? = nil) -> MCPServerConfig {
    MCPServerConfig(command: "/usr/bin/python3", args: [fixtures.appending(path: "stdio_server.py").path],
                    enabled: enabled, tools: tools)
}

private func run(_ name: String, _ arguments: String, in registry: ToolRegistry) async throws -> ToolOutput {
    let tool = try #require(await registry.tool(named: name))
    let context = ToolContext(conversationID: UUID(), turnID: UUID(), callID: "c", folders: [],
                              store: try Store(url: nil), interaction: NoInteraction())
    return try await tool.run(arguments: Data(arguments.utf8), context: context)
}

@Suite(.serialized) struct MCPManagerTests {
    @Test func discoversToolsAndCallsThem() async throws {
        let registry = ToolRegistry()
        let manager = MCPManager(registry: registry)
        await manager.apply(MCPConfig(mcpServers: ["fixture": stdioConfig()]))
        defer { Task { await manager.shutdown() } }

        try await eventually("connected") { await manager.statuses.first?.state == .connected }
        let status = try #require(await manager.statuses.first)
        #expect(status.serverInfo == "fixture 1.0")
        #expect(status.tools.contains("echo"))
        try await eventually("stderr log") { await manager.statuses.first?.log.contains("fixture started") == true }

        let catalog = await registry.catalog()
        let echo = try #require(catalog.first { $0.name == "fixture__echo" })
        #expect(echo.source == .mcp(server: "fixture"))
        #expect(echo.policy == .allow)  // readOnlyHint
        #expect(catalog.first { $0.name == "fixture__add" }?.policy == .ask)

        #expect(try await run("fixture__echo", #"{"text":"hi"}"#, in: registry) == ToolOutput("hi"))
        #expect(try await run("fixture__add", #"{"a":2,"b":3}"#, in: registry) == ToolOutput("5"))
        #expect(try await run("fixture__fail", "{}", in: registry).isError)
    }

    @Test func refreshesToolsWhenTheServerSaysSo() async throws {
        let registry = ToolRegistry()
        let manager = MCPManager(registry: registry)
        await manager.apply(MCPConfig(mcpServers: ["fixture": stdioConfig()]))
        defer { Task { await manager.shutdown() } }
        try await eventually("connected") { await manager.statuses.first?.state == .connected }

        #expect(await registry.tool(named: "fixture__secret") == nil)
        _ = try await run("fixture__unlock", "{}", in: registry)
        try await eventually("secret tool registered") { await registry.tool(named: "fixture__secret") != nil }
        #expect(try await run("fixture__secret", "{}", in: registry) == ToolOutput("42"))
    }

    @Test func reportsACrashAndDropsItsTools() async throws {
        let registry = ToolRegistry()
        let manager = MCPManager(registry: registry)
        await manager.apply(MCPConfig(mcpServers: ["fixture": stdioConfig()]))
        defer { Task { await manager.shutdown() } }
        try await eventually("connected") { await manager.statuses.first?.state == .connected }

        // The call itself fails: the server dies before answering.
        _ = try? await run("fixture__crash", "{}", in: registry)
        try await eventually("failed") {
            if case .failed = await manager.statuses.first?.state { true } else { false }
        }
        #expect(await registry.catalog().isEmpty)

        await manager.reconnect("fixture")
        try await eventually("reconnected") { await manager.statuses.first?.state == .connected }
        #expect(await registry.tool(named: "fixture__echo") != nil)
    }

    @Test func followsConfigChanges() async throws {
        let registry = ToolRegistry()
        let manager = MCPManager(registry: registry)
        defer { Task { await manager.shutdown() } }

        await manager.apply(MCPConfig(mcpServers: ["fixture": stdioConfig(enabled: false)]))
        #expect(await manager.statuses.first?.state == .disabled)
        #expect(await registry.catalog().isEmpty)

        await manager.apply(MCPConfig(mcpServers: ["fixture": stdioConfig()]))
        try await eventually("connected") { await manager.statuses.first?.state == .connected }

        // Re-applying the same configuration leaves the connection alone.
        let before = await registry.catalog()
        await manager.apply(MCPConfig(mcpServers: ["fixture": stdioConfig()]))
        #expect(await manager.statuses.first?.state == .connected)
        #expect(await registry.catalog() == before)

        await manager.apply(MCPConfig())
        #expect(await manager.statuses.isEmpty)
        #expect(await registry.catalog().isEmpty)
    }

    @Test func reportsServersThatCantStart() async throws {
        let registry = ToolRegistry()
        let manager = MCPManager(registry: registry)
        defer { Task { await manager.shutdown() } }
        await manager.apply(MCPConfig(mcpServers: [
            "missing": MCPServerConfig(command: "kuri-no-such-command-\(UUID().uuidString)"),
            "empty": MCPServerConfig(),
        ]))
        try await eventually("both failed") {
            await manager.statuses.allSatisfy { if case .failed = $0.state { true } else { false } }
        }
    }

    @Test func cancellingACallCancelsTheRequest() async throws {
        let registry = ToolRegistry()
        let manager = MCPManager(registry: registry)
        await manager.apply(MCPConfig(mcpServers: ["fixture": stdioConfig()]))
        defer { Task { await manager.shutdown() } }
        try await eventually("connected") { await manager.statuses.first?.state == .connected }

        let call = Task { try await run("fixture__slow", #"{"seconds":30}"#, in: registry) }
        try await Task.sleep(for: .milliseconds(300))
        let started = ContinuousClock.now
        call.cancel()
        await #expect(throws: CancellationError.self) { try await call.value }
        #expect(ContinuousClock.now - started < .seconds(5))
    }

    @Test func connectsOverStreamableHTTPWithHeaders() async throws {
        let server = Process()
        server.executableURL = URL(filePath: "/usr/bin/python3")
        server.arguments = [fixtures.appending(path: "http_server.py").path]
        let output = Pipe()
        server.standardOutput = output
        try server.run()
        defer { server.terminate() }
        let portLine = String(decoding: output.fileHandleForReading.availableData, as: UTF8.self)
        let port = try #require(Int(portLine.trimmingCharacters(in: .whitespacesAndNewlines)))

        let registry = ToolRegistry()
        let manager = MCPManager(registry: registry)
        defer { Task { await manager.shutdown() } }
        await manager.apply(MCPConfig(mcpServers: [
            "remote": MCPServerConfig(url: URL(string: "http://127.0.0.1:\(port)/mcp"),
                                      headers: ["Authorization": .literal("Bearer test")]),
        ]))
        try await eventually("connected") { await manager.statuses.first?.state == .connected }
        #expect(await manager.statuses.first?.serverInfo == "http-fixture 1.0")
        #expect(try await run("remote__shout", #"{"text":"hi"}"#, in: registry) == ToolOutput("HI"))
    }
}

@Suite struct MCPNamingAndPolicyTests {
    @Test func namesFitProviderLimits() {
        #expect(ToolName.mcp(server: "my server", tool: "do.thing") == "my_server__do_thing")
        #expect(ToolName.mcp(server: String(repeating: "s", count: 40), tool: String(repeating: "t", count: 40)).count == 64)
        #expect(ToolName.server(of: "github__create_issue") == "github")
        #expect(ToolName.server(of: "memory") == nil)
    }

    @Test func perServerPoliciesUseModelNames() {
        let config = MCPConfig(mcpServers: [
            "git hub": MCPServerConfig(url: URL(string: "https://example.com"), tools: ["create_*": .ask, "*": .allow]),
        ])
        #expect(config.toolPolicies == ["git_hub__create_*": .ask, "git_hub__*": .allow])
    }

    @Test func flattensContentForTheModel() {
        let text = MCPTool.text(from: [
            .text(text: "hello", annotations: nil, _meta: nil),
            .resourceLink(uri: "file:///a.txt", name: "a.txt", description: "a file"),
        ])
        #expect(text == "hello\n\n[a.txt](file:///a.txt) — a file")
    }
}
