import Foundation

public enum KuriError: Error, LocalizedError, Sendable {
    case unknownItemKind(String)
    case unknownProvider(String)
    case unsupportedWireFormat(String)
    case missingSecret(String)
    case invalidConfig(file: String, reason: String)
    case http(status: Int, body: String)
    /// The provider's server couldn't be reached, or went away mid-reply
    /// (`midway`): usually a local server that isn't running or was stopped.
    case providerUnreachable(endpoint: String, midway: Bool)
    /// The provider stayed silent for longer than a request may wait.
    case providerTimedOut(endpoint: String)
    case provider(String)
    case database(String)
    case toolNotFound(String)
    case invalidToolArguments(tool: String, reason: String)
    case memoryNotFound(Int)
    case memoryFull(total: Int, limit: Int)
    /// Another engine (the app, or `kuri` in a terminal) holds the home
    /// folder: only one runs at a time (decision 0028). `pid` is the
    /// holder's, so a client can offer to quit the other.
    case homeInUse(home: String, holder: String?, pid: Int32? = nil)

    public var errorDescription: String? {
        switch self {
        case .unknownItemKind(let kind): "Unknown item kind “\(kind)”."
        case .unknownProvider(let name): "No provider named “\(name)” in config.json."
        case .unsupportedWireFormat(let feature): "“\(feature)” isn't implemented yet."
        case .missingSecret(let ref): "Secret “\(ref)” not found."
        case .invalidConfig(let file, let reason): "\(file): \(reason)"
        case .http(let status, let body): "HTTP \(status): \(body)"
        case .providerUnreachable(let endpoint, false):
            "Couldn't reach the provider at \(endpoint). Make sure it's running."
        case .providerUnreachable(let endpoint, true):
            "The provider at \(endpoint) stopped partway through the reply. Make sure it's still running, then continue."
        case .providerTimedOut(let endpoint):
            "The provider at \(endpoint) stopped answering."
        case .provider(let message): message
        case .database(let message): "Database error: \(message)"
        case .toolNotFound(let name): "No tool named “\(name)”."
        case .invalidToolArguments(let tool, let reason): "Invalid arguments for \(tool): \(reason)"
        case .memoryNotFound(let number): "There is no active memory m\(number)."
        case .memoryFull(let total, let limit):
            "Memory would hold \(total) characters, over the \(limit) limit. Remove or shorten entries in the same call."
        case .homeInUse(let home, let holder, _):
            "\(holder ?? "Another process") is already using \(home). Quit it, then try again."
        }
    }
}
