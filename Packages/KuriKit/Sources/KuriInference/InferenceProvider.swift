import Foundation
import KuriConfig
import KuriCore

/// One adapter per wire format. Each maps the shared item model to its
/// format on the way out, and its stream back to `InferenceEvent`s.
public protocol InferenceProvider: Sendable {
    func stream(_ request: InferenceRequest) -> AsyncThrowingStream<InferenceEvent, any Error>

    /// Whether the model can be offered tools. When it can't, requests carry
    /// none and the instructions don't mention any.
    var supportsTools: Bool { get }
}

extension InferenceProvider {
    public var supportsTools: Bool { true }
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
        var headers = try resolveHeaders(config)
        let apiKey = try config.apiKey.map { try secrets.resolve($0) }

        switch config.format {
        case .openResponses:
            guard let baseURL = config.baseURL else {
                throw KuriError.invalidConfig(file: "config.json", reason: "provider “\(name)” needs a baseURL")
            }
            if let apiKey { headers["Authorization"] = "Bearer \(apiKey)" }
            return OpenResponsesProvider(name: name, baseURL: baseURL, headers: headers, session: session)
        case .appleFoundationModels:
            return AppleFoundationModelsProvider()
        case .anthropicMessages, .gemini, .chatCompletions:
            throw KuriError.unsupportedWireFormat(config.format.rawValue)
        }
    }

    /// The models a provider says it serves (`GET <baseURL>/models`).
    ///
    /// Works for every OpenAI-style server: Ollama, LM Studio, vLLM,
    /// OpenAI, OpenRouter… Other wire formats will get their own listing
    /// along with their adapters.
    public func discoverModels(name: String, config: ProviderConfig) async throws -> [String] {
        switch config.format {
        case .openResponses, .chatCompletions:
            guard let baseURL = config.baseURL else {
                throw KuriError.invalidConfig(file: "config.json", reason: "provider “\(name)” needs a baseURL")
            }
            var headers = try resolveHeaders(config)
            if let apiKey = try config.apiKey.map({ try secrets.resolve($0) }) {
                headers["Authorization"] = "Bearer \(apiKey)"
            }
            struct List: Decodable {
                struct Model: Decodable { let id: String }
                let data: [Model]
            }
            let data = try await HTTP.getJSON(session: session, url: baseURL.appending(path: "models"), headers: headers)
            return Array(Set(try JSONDecoder().decode(List.self, from: data).data.map(\.id))).sorted()
        case .appleFoundationModels:
            return try AppleFoundationModelsProvider.availableModels()
        case .anthropicMessages, .gemini:
            throw KuriError.unsupportedWireFormat("\(config.format.rawValue) model discovery")
        }
    }

    private func resolveHeaders(_ config: ProviderConfig) throws -> [String: String] {
        try (config.headers ?? [:]).mapValues { try secrets.resolve($0) }
    }
}
