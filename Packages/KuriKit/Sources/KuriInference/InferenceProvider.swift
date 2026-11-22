import Foundation
import KuriConfig
import KuriCore

/// One adapter per wire format. Each maps the shared item model to its
/// format on the way out, and its stream back to `InferenceEvent`s.
public protocol InferenceProvider: Sendable {
    func stream(_ request: InferenceRequest) -> AsyncThrowingStream<InferenceEvent, any Error>

    /// The models the provider says it serves, for `discoverModels`.
    func listModels() async throws -> [String]
}

/// Builds the provider for a `config.json` entry.
public struct ProviderFactory: Sendable {
    private let secrets: Secrets
    private let session: URLSession

    public init(secrets: Secrets = Secrets(), session: URLSession = .shared) {
        self.secrets = secrets
        self.session = session
    }

    public func make(name: String, config: ProviderConfig) throws -> any InferenceProvider {
        var headers: [String: String] = [:]
        for (key, ref) in config.headers ?? [:] {
            headers[key] = try secrets.resolve(ref)
        }
        let apiKey = try config.apiKey.map { try secrets.resolve($0) }

        switch config.format {
        case .openResponses:
            guard let baseURL = config.baseURL else {
                throw KuriError.invalidConfig(file: "config.json", reason: "provider “\(name)” needs a baseURL")
            }
            if let apiKey { headers["Authorization"] = "Bearer \(apiKey)" }
            return OpenResponsesProvider(name: name, baseURL: baseURL, headers: headers, session: session)
        case .anthropicMessages, .gemini, .chatCompletions, .appleFoundationModels:
            throw KuriError.unsupportedWireFormat(config.format.rawValue)
        }
    }
}
