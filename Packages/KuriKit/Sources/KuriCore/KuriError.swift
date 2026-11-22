import Foundation

public enum KuriError: Error, LocalizedError, Sendable {
    case unknownItemKind(String)
    case unknownProvider(String)
    case unsupportedWireFormat(String)
    case missingSecret(String)
    case invalidConfig(file: String, reason: String)
    case http(status: Int, body: String)
    case provider(String)
    case database(String)
    case toolNotFound(String)
    case invalidToolArguments(tool: String, reason: String)

    public var errorDescription: String? {
        switch self {
        case .unknownItemKind(let kind): "Unknown item kind “\(kind)”."
        case .unknownProvider(let name): "No provider named “\(name)” in config.json."
        case .unsupportedWireFormat(let format): "The “\(format)” wire format isn't implemented yet."
        case .missingSecret(let ref): "Secret “\(ref)” not found."
        case .invalidConfig(let file, let reason): "\(file): \(reason)"
        case .http(let status, let body): "HTTP \(status): \(body)"
        case .provider(let message): message
        case .database(let message): "Database error: \(message)"
        case .toolNotFound(let name): "No tool named “\(name)”."
        case .invalidToolArguments(let tool, let reason): "Invalid arguments for \(tool): \(reason)"
        }
    }
}
