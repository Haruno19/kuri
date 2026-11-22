import Foundation
import KuriCore
import KuriTools
import MCP

/// A tool discovered on an MCP server, as a Kuri `Tool`.
struct MCPTool: KuriTools.Tool {
    let spec: ToolSpec
    let defaultPolicy: ToolPolicy
    let isReadOnly: Bool
    /// The tool's name on its server.
    let originalName: String
    let connection: MCPServerConnection

    init(server: String, tool: MCP.Tool, connection: MCPServerConnection) {
        let schema = (try? JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(tool.inputSchema)))
            ?? ["type": "object"]
        spec = ToolSpec(
            name: ToolName.mcp(server: server, tool: tool.name),
            description: tool.description ?? tool.annotations.title ?? tool.title ?? "",
            parameters: schema)
        isReadOnly = tool.annotations.readOnlyHint == true
        // Read-only tools run without asking; anything that may change
        // something asks first, unless a config file says otherwise.
        defaultPolicy = isReadOnly ? .allow : .ask
        originalName = tool.name
        self.connection = connection
    }

    func run(arguments: Data, context: ToolContext) async throws -> ToolOutput {
        let values: [String: Value]
        do {
            values = arguments.isEmpty ? [:] : try JSONDecoder().decode([String: Value].self, from: arguments)
        } catch {
            return .error("Arguments must be a JSON object.")
        }
        let result = try await connection.call(originalName, arguments: values)
        return ToolOutput(Self.text(from: result.content), isError: result.isError)
    }

    /// Flattens MCP content into text for the model. Images and audio are
    /// described rather than passed on, until Kuri sends media to models.
    static func text(from content: [MCP.Tool.Content]) -> String {
        let parts = content.map { part -> String in
            switch part {
            case .text(let text, _, _):
                return text
            case .image(let data, let mimeType, _, _):
                return "[image, \(mimeType), \(data.count * 3 / 4 / 1024) KB]"
            case .audio(let data, let mimeType, _, _):
                return "[audio, \(mimeType), \(data.count * 3 / 4 / 1024) KB]"
            case .resource(let resource, _, _):
                return resource.text ?? "[resource \(resource.uri)\(resource.mimeType.map { ", \($0)" } ?? "")]"
            case .resourceLink(let uri, let name, let title, let description, _, _):
                return "[\(title ?? name)](\(uri))" + (description.map { " — \($0)" } ?? "")
            }
        }
        return parts.isEmpty ? "(no output)" : parts.joined(separator: "\n\n")
    }
}
