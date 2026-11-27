import Foundation
import OSLog
import Security

/// Minimal secret storage abstraction so licensing and API keys can be tested without the Keychain.
protocol SecureStore: AnyObject {
    func data(for account: String) throws -> Data?
    func setData(_ data: Data, for account: String) throws
    func removeData(for account: String) throws
    func contains(_ account: String) -> Bool
}

struct KeychainError: LocalizedError, Equatable {
    let status: OSStatus

    var errorDescription: String? {
        let message = SecCopyErrorMessageString(status, nil) as String? ?? "Unknown error"
        return "Keychain error \(status): \(message)"
    }
}

/// Raw generic-password items under one service. Abstracted so `SecretsVault` can be tested.
protocol KeychainItemStore: AnyObject {
    func read(_ account: String) throws -> Data?
    func write(_ data: Data, _ account: String) throws
    func delete(_ account: String) throws
}

/// The system Keychain, preferring the **data protection keychain**.
///
/// The data protection keychain is the app-scoped, iOS-style keychain: items belong to NotchDeck's
/// signing identity and macOS never shows a "wants to use your confidential information" dialog for
/// them. It needs a properly signed build (team ID). Ad-hoc signed development builds get
/// `errSecMissingEntitlement`, and fall back to the classic login keychain, whose items are bound to
/// the code signature (stable in release builds, so no prompts there either; development builds get
/// a new signature on every rebuild, hence a prompt per rebuild).
final class SystemKeychain: KeychainItemStore {
    let service: String
    private(set) var usesDataProtectionKeychain: Bool
    private let logger = Logger(subsystem: "com.notchdeck.NotchDeck", category: "Keychain")

    init(service: String = "com.notchdeck.NotchDeck", preferDataProtection: Bool = true) {
        self.service = service
        self.usesDataProtectionKeychain = preferDataProtection
    }

    private func query(_ account: String, dataProtection: Bool) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        if dataProtection { query[kSecUseDataProtectionKeychain as String] = true }
        return query
    }

    /// Falls back to the classic keychain for the rest of this run if the data protection
    /// keychain isn't available to this build.
    private func handleMissingEntitlement(_ status: OSStatus) -> Bool {
        guard status == errSecMissingEntitlement, usesDataProtectionKeychain else { return false }
        usesDataProtectionKeychain = false
        logger.notice("Data protection keychain unavailable (unsigned/ad-hoc build); using the login keychain")
        return true
    }

    private func copy(_ account: String, dataProtection: Bool) -> (OSStatus, Data?) {
        var query = query(account, dataProtection: dataProtection)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        return (status, result as? Data)
    }

    func read(_ account: String) throws -> Data? {
        if usesDataProtectionKeychain {
            let (status, data) = copy(account, dataProtection: true)
            if handleMissingEntitlement(status) { return try read(account) }
            switch status {
            case errSecSuccess:
                return data
            case errSecItemNotFound:
                // An item written by an older / unsigned build lives in the login keychain. Move it into
                // the data protection keychain, but delete the login copy only once the copy has really
                // landed there. (Development builds can *read* the data protection keychain, getting
                // "not found", yet can't write to it; the old code then wrote back to the login keychain
                // and deleted that same item, so secrets vanished on every other launch.)
                let (legacyStatus, legacyData) = copy(account, dataProtection: false)
                guard legacyStatus == errSecSuccess, let legacyData else { return nil }
                if addToDataProtectionKeychain(legacyData, account) {
                    SecItemDelete(query(account, dataProtection: false) as CFDictionary)
                }
                return legacyData
            default:
                throw KeychainError(status: status)
            }
        }
        let (status, data) = copy(account, dataProtection: false)
        switch status {
        case errSecSuccess: return data
        case errSecItemNotFound: return nil
        default: throw KeychainError(status: status)
        }
    }

    /// Adds a copy to the data protection keychain. False (and the login keychain is used for the rest
    /// of this run) when this build can't write there.
    private func addToDataProtectionKeychain(_ data: Data, _ account: String) -> Bool {
        var item = query(account, dataProtection: true)
        item[kSecValueData as String] = data
        item[kSecAttrLabel as String] = "NotchDeck"
        item[kSecAttrDescription as String] = "NotchDeck license and API keys"
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        let status = SecItemAdd(item as CFDictionary, nil)
        if status == errSecSuccess { return true }
        if !handleMissingEntitlement(status) {
            logger.error("Couldn't move \(account, privacy: .public) to the data protection keychain: \(status); keeping the login keychain copy")
        }
        usesDataProtectionKeychain = false
        return false
    }

    func write(_ data: Data, _ account: String) throws {
        let dataProtection = usesDataProtectionKeychain
        let base = query(account, dataProtection: dataProtection)
        let status = SecItemUpdate(base as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if handleMissingEntitlement(status) { return try write(data, account) }
        switch status {
        case errSecSuccess:
            return
        case errSecItemNotFound:
            var item = base
            item[kSecValueData as String] = data
            // Shown as the item's name in Keychain Access and in any macOS prompt.
            item[kSecAttrLabel as String] = "NotchDeck"
            item[kSecAttrDescription as String] = "NotchDeck license and API keys"
            if dataProtection { item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock }
            let addStatus = SecItemAdd(item as CFDictionary, nil)
            if handleMissingEntitlement(addStatus) { return try write(data, account) }
            guard addStatus == errSecSuccess else { throw KeychainError(status: addStatus) }
        default:
            throw KeychainError(status: status)
        }
    }

    func delete(_ account: String) throws {
        for dataProtection in [true, false] {
            let status = SecItemDelete(query(account, dataProtection: dataProtection) as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound || status == errSecMissingEntitlement else {
                throw KeychainError(status: status)
            }
        }
    }
}

/// Every NotchDeck secret (license record, API keys) in **one** Keychain item, read once per launch
/// and kept in memory. One item means at most one macOS prompt (development builds only); the cache
/// means secrets are never re-read per chat message or per license check.
final class SecretsVault: SecureStore {
    static let account = "secrets"

    private let items: KeychainItemStore
    /// Per-secret items written by Phase 2–4 builds, merged into the vault once.
    private let legacyAccounts: [String]
    private var cache: [String: Data]?

    init(items: KeychainItemStore, legacyAccounts: [String] = []) {
        self.items = items
        self.legacyAccounts = legacyAccounts
    }

    private enum VaultError: Error { case unreadable }

    private func load() throws -> [String: Data] {
        if let cache { return cache }
        var secrets: [String: Data] = [:]
        if let blob = try items.read(Self.account) {
            guard let decoded = try? JSONDecoder().decode([String: Data].self, from: blob) else { throw VaultError.unreadable }
            secrets = decoded
        } else {
            for account in legacyAccounts {
                if let data = try? items.read(account) { secrets[account] = data }
            }
            if !secrets.isEmpty {
                try items.write(JSONEncoder().encode(secrets), Self.account)
                for account in secrets.keys { try? items.delete(account) }
            }
        }
        cache = secrets
        return secrets
    }

    private func save(_ secrets: [String: Data]) throws {
        try items.write(JSONEncoder().encode(secrets), Self.account)
        cache = secrets
    }

    func data(for account: String) throws -> Data? {
        try load()[account]
    }

    func setData(_ data: Data, for account: String) throws {
        var secrets = try load()
        guard secrets[account] != data else { return }
        secrets[account] = data
        try save(secrets)
    }

    func removeData(for account: String) throws {
        var secrets = try load()
        guard secrets.removeValue(forKey: account) != nil else { return }
        try save(secrets)
    }

    func contains(_ account: String) -> Bool {
        (try? load())?[account] != nil
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
