import Foundation
import Security

/// Thread-safe Keychain wrapper for storing provider API keys.
/// Uses `kSecClassGenericPassword` with the app's bundle identifier as the service name.
enum KeychainManager {

    private static let service = Bundle.main.bundleIdentifier ?? "com.adityamedidala.CircleSearch"

    // MARK: Per-provider API (preferred)

    /// Persists `value` in the Keychain for the given provider, creating or updating as needed.
    static func save(_ value: String, for provider: ProviderType) throws {
        guard let data = value.data(using: .utf8) else { return }
        let query = baseQuery(for: provider)
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData: data] as CFDictionary)
        if status == errSecItemNotFound {
            var addItem = query
            addItem[kSecValueData] = data
            let addStatus = SecItemAdd(addItem as CFDictionary, nil)
            guard addStatus == errSecSuccess else { throw KeychainError.save(addStatus) }
        } else if status != errSecSuccess {
            throw KeychainError.save(status)
        }
    }

    /// Returns the stored API key for the given provider, or `nil` if none is saved.
    static func load(for provider: ProviderType) -> String? {
        var query = baseQuery(for: provider)
        query[kSecReturnData] = true
        query[kSecMatchLimit] = kSecMatchLimitOne
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data   = result as? Data,
              let string = String(data: data, encoding: .utf8)
        else { return nil }
        return string
    }

    /// Removes the stored API key for the given provider. No-ops silently if none is present.
    static func delete(for provider: ProviderType) throws {
        let status = SecItemDelete(baseQuery(for: provider) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.delete(status)
        }
    }

    // MARK: Legacy single-provider API (delegates to .anthropic)

    /// - Note: Retained for backward compatibility with `SettingsView` (Phase 1).
    ///   Will be removed when the Providers tab lands in Phase 4.
    static func save(_ value: String) throws { try save(value, for: .anthropic) }
    static func load()              -> String? { load(for: .anthropic) }
    static func delete()            throws     { try delete(for: .anthropic) }

    // MARK: Private

    private static func baseQuery(for provider: ProviderType) -> [CFString: Any] {
        [
            kSecClass:       kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: provider.keychainAccount,
        ]
    }

    // MARK: Errors

    enum KeychainError: LocalizedError {
        case save(OSStatus)
        case delete(OSStatus)

        var errorDescription: String? {
            switch self {
            case .save(let s):   return "Failed to save API key (OSStatus \(s))."
            case .delete(let s): return "Failed to delete API key (OSStatus \(s))."
            }
        }
    }
}
