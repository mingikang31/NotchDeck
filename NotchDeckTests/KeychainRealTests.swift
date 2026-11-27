import Foundation
import Security
import Testing
@testable import NotchDeck

/// Runs against the real login / data-protection keychain under a throwaway service name
/// (never NotchDeck's own item), and removes everything it creates.
@Suite(.serialized)
struct KeychainRealTests {
    private func cleanUp(_ service: String) {
        for dataProtection in [true, false] {
            var query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service]
            if dataProtection { query[kSecUseDataProtectionKeychain as String] = true }
            SecItemDelete(query as CFDictionary)
        }
    }

    /// Regression: on development builds the data-protection keychain isn't writable, so "migrating" a
    /// login-keychain item wrote it back to the login keychain and then deleted it: secrets survived one
    /// launch, vanished on the next, came back once re-entered, and so on.
    @Test func secretsSurviveRepeatedLaunches() throws {
        let service = "com.notchdeck.tests.\(UUID().uuidString)"
        defer { cleanUp(service) }

        // An existing item in the login keychain (what every development build so far has written).
        try SystemKeychain(service: service, preferDataProtection: false).write(Data("v1".utf8), "secrets")

        for launch in 1...3 {
            let keychain = SystemKeychain(service: service)    // a fresh launch
            let data = try keychain.read("secrets")
            #expect(data == Data("v1".utf8), "launch \(launch)")
        }
    }

    /// A secret saved in one launch is there in the next, whichever keychain this build can use.
    @Test func writeThenReadAcrossLaunches() throws {
        let service = "com.notchdeck.tests.\(UUID().uuidString)"
        defer { cleanUp(service) }
        try SystemKeychain(service: service).write(Data("first".utf8), "secrets")
        #expect(try SystemKeychain(service: service).read("secrets") == Data("first".utf8))
        try SystemKeychain(service: service).write(Data("second".utf8), "secrets")
        for _ in 1...3 {
            #expect(try SystemKeychain(service: service).read("secrets") == Data("second".utf8))
        }
    }

    /// End to end through the vault: an API key saved once is still there after several relaunches.
    @Test func apiKeySurvivesRelaunches() throws {
        let service = "com.notchdeck.tests.\(UUID().uuidString)"
        defer { cleanUp(service) }
        try APIKeyStore(store: SecretsVault(items: SystemKeychain(service: service))).save("sk-test-123", for: .anthropic)
        for _ in 1...3 {
            let keys = APIKeyStore(store: SecretsVault(items: SystemKeychain(service: service)))
            keys.refresh()
            #expect(keys.savedProviders == [.anthropic])
            #expect(try keys.key(for: .anthropic) == "sk-test-123")
        }
    }
}
