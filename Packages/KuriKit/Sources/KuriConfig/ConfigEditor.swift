import Foundation
import KuriCore

/// Changes `config.json` on the user's behalf (from the app's settings).
///
/// The file is edited as a generic JSON tree, so keys Kuri doesn't know
/// about survive. What doesn't survive is formatting and comments: the
/// result is written back as tidy JSON5, with a header saying so. The
/// edited tree must still decode as a `Config`, or nothing is written.
public struct ConfigEditor: Sendable {
    public let home: KuriHome

    public init(home: KuriHome) {
        self.home = home
    }

    static let header = """
        Kuri configuration. JSON5: comments, unquoted keys and trailing commas are fine.
        Kuri rewrites this file when you change models from the app; comments are not kept.
        """

    public func edit(_ change: (inout JSONValue) throws -> Void) throws {
        let data = try Data(contentsOf: home.configFile)
        var tree = try ConfigLoader.decode(JSONValue.self, from: data)
        guard case .object = tree else {
            throw KuriError.invalidConfig(file: "config.json", reason: "the top level must be an object")
        }
        try change(&tree)
        let text = JSON5Writer.write(tree, header: Self.header)
        // Refuse to write something Kuri itself couldn't load.
        _ = try ConfigLoader.decode(Config.self, from: Data(text.utf8))
        try Data(text.utf8).write(to: home.configFile, options: .atomic)
    }

    // MARK: Models

    /// Adds a model to a provider, or replaces the entry with the same id.
    public func register(_ model: ModelConfig, provider: String) throws {
        try edit { tree in
            var models = try Self.models(of: provider, in: tree)
            let entry = Self.entry(for: model)
            if let index = models.firstIndex(where: { Self.id(of: $0) == model.id }) {
                models[index] = entry
            } else {
                models.append(entry)
            }
            try Self.setModels(models, of: provider, in: &tree)
        }
    }

    public func unregister(model id: String, provider: String) throws {
        try edit { tree in
            let models = try Self.models(of: provider, in: tree).filter { Self.id(of: $0) != id }
            try Self.setModels(models, of: provider, in: &tree)
        }
    }

    public func setDefaultModel(_ ref: ModelRef?) throws {
        try edit { tree in
            guard case .object(var root) = tree else { return }
            root["defaultModel"] = ref.map { .string($0.description) }
            tree = .object(root)
        }
    }

    // MARK: Tree helpers

    private static func provider(_ name: String, in tree: JSONValue) throws -> [String: JSONValue] {
        guard case .object(let providers) = tree["providers"] ?? .null,
              case .object(let provider) = providers[name] ?? .null
        else {
            throw KuriError.unknownProvider(name)
        }
        return provider
    }

    private static func models(of name: String, in tree: JSONValue) throws -> [JSONValue] {
        if case .array(let models) = try provider(name, in: tree)["models"] ?? .null { return models }
        return []
    }

    private static func setModels(_ models: [JSONValue], of name: String, in tree: inout JSONValue) throws {
        var provider = try provider(name, in: tree)
        provider["models"] = .array(models)
        guard case .object(var root) = tree, case .object(var providers) = root["providers"] ?? .null else { return }
        providers[name] = .object(provider)
        root["providers"] = .object(providers)
        tree = .object(root)
    }

    private static func id(of entry: JSONValue) -> String? {
        entry.stringValue ?? entry["id"]?.stringValue
    }

    /// A bare id when that's all there is, an object otherwise.
    static func entry(for model: ModelConfig) -> JSONValue {
        var object: [String: JSONValue] = ["id": .string(model.id)]
        if let name = model.name { object["name"] = .string(name) }
        if let value = model.contextWindow { object["contextWindow"] = .number(Double(value)) }
        if let value = model.maxOutputTokens { object["maxOutputTokens"] = .number(Double(value)) }
        if let value = model.reasoningEffort { object["reasoningEffort"] = .string(value) }
        if let value = model.fallbacks, !value.isEmpty { object["fallbacks"] = .array(value.map { .string($0.description) }) }
        return object.count == 1 ? .string(model.id) : .object(object)
    }
}
