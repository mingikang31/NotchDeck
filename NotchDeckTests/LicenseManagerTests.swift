import CryptoKit
import Foundation
import Testing
@testable import NotchDeck

// MARK: - Test doubles

final class TestClock {
    var now = Date(timeIntervalSince1970: 1_800_000_000)
    func advance(days: Double) { now = now.addingTimeInterval(days * 86_400) }
}

/// Plays the license proxy: signs receipts with its own key, records calls.
final class MockLicenseServer: LicenseActivating {
    let signingKey = Curve25519.Signing.PrivateKey()
    var publicKey: Curve25519.Signing.PublicKey { signingKey.publicKey }
    let masterKey = "NDMK-TESTS-ONLY2-ABCDE-FGHJK-LMNPQ"

    var activations: [String] = []
    var deactivatedInstances: [String] = []
    var machineIDOverride: String?
    var signWith: Curve25519.Signing.PrivateKey?

    func activate(licenseKey: String, machineID: String, machineName: String) async throws -> SignedLicenseReceipt {
        let isMaster = licenseKey.uppercased() == masterKey
        guard isMaster || licenseKey.hasPrefix("TEST-") else {
            throw LicenseAPIError.rejected(message: "This license key isn't valid.", statusCode: 403)
        }
        activations.append(licenseKey)
        return try makeReceipt(
            edition: isMaster ? "master" : "standard",
            hint: String(licenseKey.suffix(4)).uppercased(),
            machineID: machineIDOverride ?? machineID,
            instanceID: "inst-\(activations.count)"
        )
    }

    func deactivate(licenseKey: String, machineID: String, instanceID: String) async throws {
        deactivatedInstances.append(instanceID)
    }

    func makeReceipt(edition: String, hint: String, machineID: String, instanceID: String, product: String = "notchdeck") throws -> SignedLicenseReceipt {
        let payload: [String: Any] = [
            "v": 1, "product": product, "edition": edition, "license_key_hint": hint,
            "machine_id": machineID, "instance_id": instanceID,
            "issued_at": "2026-11-25T12:00:00.123Z", "customer_name": NSNull(),
        ]
        let data = try JSONSerialization.data(withJSONObject: payload)
        let signature = try (signWith ?? signingKey).signature(for: data)
        return SignedLicenseReceipt(payload: data.base64EncodedString(), signature: signature.base64EncodedString())
    }
}

final class FailingSecureStore: SecureStore {
    func data(for account: String) throws -> Data? { throw KeychainError(status: errSecAuthFailed) }
    func setData(_ data: Data, for account: String) throws { throw KeychainError(status: errSecAuthFailed) }
    func removeData(for account: String) throws {}
    func contains(_ account: String) -> Bool { false }
}

private struct Harness {
    let store = InMemorySecureStore()
    let server = MockLicenseServer()
    let clock = TestClock()

    func manager(machineID: String = "machine-A", store: SecureStore? = nil) -> LicenseManager {
        let clock = clock
        return LicenseManager(
            store: store ?? self.store,
            configuration: LicenseConfiguration(apiBaseURL: URL(string: "https://license.test"), publicKey: server.publicKey, purchaseURL: nil),
            client: server,
            machineID: machineID,
            machineName: "Test Mac",
            now: { clock.now }
        )
    }

    func vault() throws -> LicenseVault {
        try JSONDecoder().decode(LicenseVault.self, from: #require(try store.data(for: LicenseManager.vaultAccount)))
    }

    func write(_ vault: LicenseVault) throws {
        try store.setData(JSONEncoder().encode(vault), for: LicenseManager.vaultAccount)
    }
}

// MARK: - Trial

struct TrialTests {
    @Test func firstLaunchStartsSevenDayTrial() {
        let h = Harness()
        let m = h.manager()
        m.refresh()
        #expect(m.status == .trial(daysRemaining: 7, endsAt: h.clock.now.addingTimeInterval(LicenseManager.trialDuration)))
        #expect(m.isUnlocked)
        #expect(m.trialBadgeText == "7 days left in free trial")
    }

    @Test func trialCountsDownInWholeDays() {
        let h = Harness()
        h.manager().refresh()
        h.clock.advance(days: 3.05)
        let m = h.manager()
        m.refresh()
        guard case .trial(let days, _) = m.status else { Issue.record("expected trial, got \(m.status)"); return }
        #expect(days == 4)
    }

    @Test func trialExpiresAfterSevenDaysAndSurvivesRelaunch() {
        let h = Harness()
        h.manager().refresh()
        h.clock.advance(days: 7.001)
        let relaunched = h.manager()
        relaunched.refresh()
        #expect(relaunched.status == .trialExpired(.elapsed))
        #expect(!relaunched.isUnlocked)
    }

    @Test func settingTheClockBackDoesNotExtendTheTrial() {
        let h = Harness()
        let m = h.manager()
        m.refresh()
        h.clock.advance(days: 6)
        m.refresh()                       // records lastSeen at day 6
        h.clock.advance(days: -6)         // user rolls the clock back to day 0
        m.refresh()
        guard case .trial(let days, _) = m.status else { Issue.record("expected trial, got \(m.status)"); return }
        #expect(days == 1)
    }

    @Test func editingTheTrialStartIsDetected() throws {
        let h = Harness()
        h.manager().refresh()
        var vault = try h.vault()
        vault.trialStartedAt = vault.trialStartedAt.addingTimeInterval(30 * 86_400)
        try h.write(vault)
        let m = h.manager()
        m.refresh()
        #expect(m.status == .trialExpired(.tampered))
    }

    @Test func vaultCopiedToAnotherMacIsRejected() {
        let h = Harness()
        h.manager(machineID: "machine-A").refresh()
        let other = h.manager(machineID: "machine-B")
        other.refresh()
        #expect(other.status == .trialExpired(.tampered))
    }

    @Test func corruptedVaultIsNotTreatedAsAFreshTrial() throws {
        let h = Harness()
        try h.store.setData(Data("garbage".utf8), for: LicenseManager.vaultAccount)
        let m = h.manager()
        m.refresh()
        #expect(m.status == .trialExpired(.tampered))
    }

    @Test func keychainFailureKeepsTheAppUnlocked() {
        let h = Harness()
        let m = h.manager(store: FailingSecureStore())
        m.refresh()
        guard case .storageUnavailable = m.status else { Issue.record("expected storageUnavailable, got \(m.status)"); return }
        #expect(m.isUnlocked)
    }
}

// MARK: - Activation

struct ActivationTests {
    @Test func activationUnlocksAnExpiredTrialAndPersists() async {
        let h = Harness()
        h.manager().refresh()
        h.clock.advance(days: 10)
        let m = h.manager()
        m.refresh()
        #expect(!m.isUnlocked)

        #expect(await m.activate(licenseKey: "  TEST-AAAA-BBBB-CCCC \n"))
        guard case .licensed(let summary) = m.status else { Issue.record("expected licensed, got \(m.status)"); return }
        #expect(summary.edition == .standard)
        #expect(summary.keyHint == "CCCC")
        #expect(h.server.activations == ["TEST-AAAA-BBBB-CCCC"])

        let relaunched = h.manager()
        relaunched.refresh()
        #expect(relaunched.isLicensed)
    }

    @Test func masterKeyActivatesMasterEditionCaseInsensitively() async {
        let h = Harness()
        let m = h.manager()
        m.refresh()
        #expect(await m.activate(licenseKey: h.server.masterKey.lowercased()))
        guard case .licensed(let summary) = m.status else { Issue.record("expected licensed, got \(m.status)"); return }
        #expect(summary.edition == .master)
    }

    @Test func rejectedKeySurfacesTheServerMessage() async {
        let h = Harness()
        let m = h.manager()
        m.refresh()
        #expect(await m.activate(licenseKey: "WRONG-KEY-1234") == false)
        #expect(m.lastError == "This license key isn't valid.")
        #expect(!m.isLicensed)
    }

    @Test func implausibleKeyIsNeverSent() async {
        let h = Harness()
        let m = h.manager()
        #expect(await m.activate(licenseKey: "abc") == false)
        #expect(await m.activate(licenseKey: "TEST-<script>-1234") == false)
        #expect(h.server.activations.isEmpty)
    }

    @Test func receiptBoundToAnotherMachineIsRejected() async {
        let h = Harness()
        h.server.machineIDOverride = "someone-elses-mac"
        let m = h.manager()
        m.refresh()
        #expect(await m.activate(licenseKey: "TEST-AAAA-BBBB-CCCC") == false)
        #expect(!m.isLicensed)
    }

    @Test func receiptSignedByAnUnknownKeyIsRejected() async {
        let h = Harness()
        h.server.signWith = Curve25519.Signing.PrivateKey()
        let m = h.manager()
        m.refresh()
        #expect(await m.activate(licenseKey: "TEST-AAAA-BBBB-CCCC") == false)
        #expect(!m.isLicensed)
    }

    @Test func deactivationReleasesTheSeatAndRelocks() async {
        let h = Harness()
        let m = h.manager()
        m.refresh()
        #expect(await m.activate(licenseKey: "TEST-AAAA-BBBB-CCCC"))
        h.clock.advance(days: 30)
        #expect(await m.deactivate())
        #expect(h.server.deactivatedInstances == ["inst-1"])
        #expect(m.status == .trialExpired(.elapsed))
    }

    @Test func unconfiguredBuildExplainsWhyActivationIsUnavailable() async {
        let m = LicenseManager(
            store: InMemorySecureStore(),
            configuration: LicenseConfiguration(apiBaseURL: nil, publicKey: nil, purchaseURL: nil),
            client: nil,
            machineID: "machine-A",
            machineName: "Test Mac"
        )
        #expect(await m.activate(licenseKey: "TEST-AAAA-BBBB-CCCC") == false)
        #expect(m.lastError == "License activation isn't configured in this build.")
    }
}

// MARK: - Secrets vault

/// In-memory stand-in for Keychain items that counts reads (each read of a real item can prompt).
final class CountingKeychainItems: KeychainItemStore {
    var items: [String: Data] = [:]
    var reads: [String] = []
    func read(_ account: String) throws -> Data? { reads.append(account); return items[account] }
    func write(_ data: Data, _ account: String) throws { items[account] = data }
    func delete(_ account: String) throws { items[account] = nil }
}

struct SecretsVaultTests {
    @Test func allSecretsLiveInOneItemReadOncePerLaunch() throws {
        let items = CountingKeychainItems()
        let vault = SecretsVault(items: items)
        try vault.setData(Data("vault".utf8), for: "license.vault")
        try vault.setData(Data("sk-ant".utf8), for: "api.anthropic")
        #expect(Array(items.items.keys) == [SecretsVault.account])

        let relaunched = SecretsVault(items: items)
        items.reads = []
        for _ in 0..<5 {
            _ = try relaunched.data(for: "api.anthropic")
            _ = relaunched.contains("license.vault")
        }
        #expect(items.reads == [SecretsVault.account]) // one Keychain read, however often secrets are used
        #expect(try relaunched.data(for: "api.anthropic") == Data("sk-ant".utf8))
    }

    @Test func migratesPerSecretItemsFromEarlierBuildsOnce() throws {
        let items = CountingKeychainItems()
        items.items = ["license.vault": Data("trial".utf8), "api.gemini": Data("AIza".utf8)]
        let vault = SecretsVault(items: items, legacyAccounts: ["license.vault", "api.anthropic", "api.gemini"])

        #expect(try vault.data(for: "license.vault") == Data("trial".utf8))
        #expect(vault.contains("api.gemini"))
        #expect(!vault.contains("api.anthropic"))
        #expect(Array(items.items.keys) == [SecretsVault.account]) // old items removed after merging
    }

    @Test func removingASecretPersists() throws {
        let items = CountingKeychainItems()
        let vault = SecretsVault(items: items)
        try vault.setData(Data("x".utf8), for: "api.gemini")
        try vault.removeData(for: "api.gemini")
        #expect(!SecretsVault(items: items).contains("api.gemini"))
    }
}
