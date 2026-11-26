import Foundation
import KuriConfig
import KuriCore
import MCP

/// One live connection to one MCP server: the SDK client plus its transport.
actor MCPServerConnection {
    struct Handlers: Sendable {
        /// A line of the server's log (stderr, for stdio servers).
        var log: @Sendable (String) -> Void
        /// The server process ended; the connection is unusable.
        var exited: @Sendable (String) -> Void
        /// The server announced that its tool list changed.
        var toolsChanged: @Sendable () -> Void
    }

    static let connectTimeout: Duration = .seconds(60)

    let name: String
    private let client = Client(name: "Kuri", version: "0.2.1")
    private var transport: (any Transport)?

    init(name: String) {
        self.name = name
    }

    /// Connects and performs the MCP handshake.
    ///
    /// - Parameters:
    ///   - environment: The full environment for a stdio server.
    ///   - headers: Resolved HTTP headers for a remote server.
    func start(config: MCPServerConfig, environment: [String: String], headers: [String: String],
               handlers: Handlers) async throws -> Initialize.Result {
        let transport: any Transport
        if let command = config.command {
            transport = ProcessTransport(
                command: command, arguments: config.args ?? [], environment: environment,
                onStderr: handlers.log,
                onExit: { status in handlers.exited(status == 0 ? "exited" : "exited with status \(status)") })
        } else if let url = config.url {
            transport = HTTPClientTransport(endpoint: url, streaming: true, requestModifier: { request in
                var request = request
                for (field, value) in headers { request.setValue(value, forHTTPHeaderField: field) }
                return request
            })
        } else {
            throw KuriError.invalidConfig(file: "mcp.json", reason: "server “\(name)” needs a command or a url")
        }
        self.transport = transport

        await client.onNotification(ToolListChangedNotification.self) { _ in handlers.toolsChanged() }

        let client = client
        return try await withThrowingTaskGroup(of: Initialize.Result.self) { group in
            group.addTask { try await client.connect(transport: transport) }
            group.addTask {
                try await Task.sleep(for: Self.connectTimeout)
                throw KuriError.provider("No answer from the server within \(Self.connectTimeout.components.seconds) seconds.")
            }
            defer { group.cancelAll() }
            return try await group.next()!
        }
    }

    /// Every tool the server offers, following pagination.
    func listTools() async throws -> [MCP.Tool] {
        var tools: [MCP.Tool] = []
        var cursor: String?
        repeat {
            let page = try await client.listTools(cursor: cursor)
            tools += page.tools
            cursor = page.nextCursor
        } while cursor != nil
        return tools
    }

    /// Calls a tool. Cancelling the calling task cancels the request on the
    /// server too.
    func call(_ tool: String, arguments: [String: Value]) async throws -> (content: [MCP.Tool.Content], isError: Bool) {
        let context: RequestContext<CallTool.Result> = try await client.callTool(name: tool, arguments: arguments)
        let client = client
        let result = try await withTaskCancellationHandler {
            try await context.value
        } onCancel: {
            Task { try? await client.cancelRequest(context.requestID, reason: "Cancelled by the user") }
        }
        return (result.content, result.isError ?? false)
    }

    func stop() async {
        await client.disconnect()
        await transport?.disconnect()
        transport = nil
    }
}
