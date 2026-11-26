import Foundation
import Security

/// Minimal secret storage abstraction so licensing and API keys can be tested without the Keychain.
protocol SecureStore: AnyObject {
    func data(for account: String) throws -> Data?
    func setData(_ data: Data, for account: String) throws
    func removeData(for account: String) throws
    /// Existence check that reads attributes only (no secret decryption, so no access prompt).
    func contains(_ account: String) -> Bool
}

struct KeychainError: LocalizedError, Equatable {
    let status: OSStatus

    var errorDescription: String? {
        let message = SecCopyErrorMessageString(status, nil) as String? ?? "Unknown error"
        return "Keychain error \(status): \(message)"
    }
}

/// Generic-password Keychain storage scoped to one service name.
///
/// Note for development: items are bound to the app's code signature. Ad-hoc signed Debug
/// builds get a new signature on every rebuild, so macOS asks once per rebuild to allow access.
/// Signing with a Development Team (stable designated requirement) removes those prompts.
final class KeychainHelper: SecureStore {
    let service: String

    init(service: String = "com.notchdeck.NotchDeck") {
        self.service = service
    }

    private func baseQuery(_ account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    func data(for account: String) throws -> Data? {
        var query = baseQuery(account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess: return result as? Data
        case errSecItemNotFound: return nil
        default: throw KeychainError(status: status)
        }
    }

    func setData(_ data: Data, for account: String) throws {
        let update = [kSecValueData as String: data] as CFDictionary
        let status = SecItemUpdate(baseQuery(account) as CFDictionary, update)
        switch status {
        case errSecSuccess:
            return
        case errSecItemNotFound:
            var item = baseQuery(account)
            item[kSecValueData as String] = data
            item[kSecAttrLabel as String] = "NotchDeck (\(account))"
            let addStatus = SecItemAdd(item as CFDictionary, nil)
            guard addStatus == errSecSuccess else { throw KeychainError(status: addStatus) }
        default:
            throw KeychainError(status: status)
        }
    }

    func removeData(for account: String) throws {
        let status = SecItemDelete(baseQuery(account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw KeychainError(status: status) }
    }

    func contains(_ account: String) -> Bool {
        var query = baseQuery(account)
        query[kSecReturnAttributes as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        return SecItemCopyMatching(query as CFDictionary, nil) == errSecSuccess
    }
}

/// Volatile store for tests and the `-notchdeck.debug.ephemeralSecureStore YES` launch flag.
final class InMemorySecureStore: SecureStore {
    private var items: [String: Data] = [:]

    func data(for account: String) throws -> Data? { items[account] }
    func setData(_ data: Data, for account: String) throws { items[account] = data }
    func removeData(for account: String) throws { items[account] = nil }
    func contains(_ account: String) -> Bool { items[account] != nil }
}
