import Foundation
import Security

/// Thread-safe Keychain wrapper for storing the Anthropic API key.
/// Uses `kSecClassGenericPassword` with the app's bundle identifier as the service name.
enum KeychainManager {

    private static let service = Bundle.main.bundleIdentifier ?? "com.adityamedidala.CircleSearch"
    private static let account = "anthropic-api-key"

    // MARK: Public

    /// Persists `value` in the Keychain, creating or updating the item as needed.
    static func save(_ value: String) throws {
        guard let data = value.data(using: .utf8) else { return }

        let query: [CFString: Any] = [
            kSecClass:       kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
        ]

        // Try update first; add if the item doesn't exist yet.
        let updateStatus = SecItemUpdate(query as CFDictionary, [kSecValueData: data] as CFDictionary)
        if updateStatus == errSecItemNotFound {
            var addItem = query
            addItem[kSecValueData] = data
            let addStatus = SecItemAdd(addItem as CFDictionary, nil)
            guard addStatus == errSecSuccess else { throw KeychainError.save(addStatus) }
        } else if updateStatus != errSecSuccess {
            throw KeychainError.save(updateStatus)
        }
    }

    /// Returns the stored API key, or `nil` if none is saved.
    static func load() -> String? {
        let query: [CFString: Any] = [
            kSecClass:            kSecClassGenericPassword,
            kSecAttrService:      service,
            kSecAttrAccount:      account,
            kSecReturnData:       true,
            kSecMatchLimit:       kSecMatchLimitOne,
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data,
              let string = String(data: data, encoding: .utf8)
        else { return nil }
        return string
    }

    /// Removes the stored API key. No-ops silently if no key is present.
    static func delete() throws {
        let query: [CFString: Any] = [
            kSecClass:       kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.delete(status)
        }
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
