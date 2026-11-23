import Foundation
import KuriCore
import Security

/// A reference to a secret, as written in a config file.
///
/// - `keychain:<name>` — a generic password Kuri stored under that name
/// - `env:<VAR>` — an environment variable
/// - anything else — the literal value (works, but it sits in a plain file)
public enum SecretRef: Sendable, Hashable, Codable, CustomStringConvertible {
    case keychain(String)
    case environment(String)
    case literal(String)

    public init(_ string: String) {
        if string.hasPrefix("keychain:") {
            self = .keychain(String(string.dropFirst("keychain:".count)))
        } else if string.hasPrefix("env:") {
            self = .environment(String(string.dropFirst("env:".count)))
        } else {
            self = .literal(string)
        }
    }

    /// How it's written in a config file.
    public var reference: String {
        switch self {
        case .keychain(let name): "keychain:\(name)"
        case .environment(let name): "env:\(name)"
        case .literal(let value): value
        }
    }

    /// Like `reference`, without a literal's value: safe for messages.
    public var description: String {
        switch self {
        case .keychain(let name): "keychain:\(name)"
        case .environment(let name): "env:\(name)"
        case .literal: "<literal>"
        }
    }

    public init(from decoder: any Decoder) throws {
        self.init(try decoder.singleValueContainer().decode(String.self))
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(reference)
    }
}

/// Resolves secret references and stores secrets in the Keychain.
public struct Secrets: Sendable {
    public static let keychainService = "Kuri"

    private let environment: [String: String]

    public init(environment: [String: String] = ProcessInfo.processInfo.environment) {
        self.environment = environment
    }

    public func resolve(_ ref: SecretRef) throws -> String {
        switch ref {
        case .literal(let value):
            return value
        case .environment(let name):
            guard let value = environment[name] else { throw KuriError.missingSecret(ref.description) }
            return value
        case .keychain(let name):
            guard let value = Self.readKeychain(name) else { throw KuriError.missingSecret(ref.description) }
            return value
        }
    }

    public static func readKeychain(_ name: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: name,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data
        else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Whether a secret is stored under `name`, without reading it.
    public static func hasKeychainItem(_ name: String) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: name,
        ]
        return SecItemCopyMatching(query as CFDictionary, nil) == errSecSuccess
    }

    /// Creates or replaces the secret stored under `name`.
    public static func storeKeychain(_ name: String, value: String) throws {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: name,
        ]
        SecItemDelete(base as CFDictionary)
        var attributes = base
        attributes[kSecValueData as String] = Data(value.utf8)
        let status = SecItemAdd(attributes as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw KuriError.provider("Keychain write failed (\(status)).")
        }
    }

    /// Deletes the secret stored under `name`, if there is one.
    public static func deleteKeychain(_ name: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: name,
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KuriError.provider("Keychain delete failed (\(status)).")
        }
    }
}
