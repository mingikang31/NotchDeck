import AppKit
import CryptoKit
import Foundation
import Observation

// MARK: - Configuration

/// Licensing endpoints and keys, read from Info.plist (populated by Config/NotchDeck.xcconfig).
struct LicenseConfiguration {
    static let defaultTrialDays = 7
    static let trialDaysRange = 1...365

    var apiBaseURL: URL?
    var publicKey: Curve25519.Signing.PublicKey?
    var purchaseURL: URL?
    /// Free-trial length. 7 normally; tester builds can set more (`TRIAL_DAYS`, see
    /// Scripts/package-for-testers.sh).
    var trialDays = LicenseConfiguration.defaultTrialDays

    var isActivationAvailable: Bool { apiBaseURL != nil && publicKey != nil }
    var trialDuration: TimeInterval { TimeInterval(trialDays) * 24 * 60 * 60 }

    /// `NDTrialDays` from Info.plist: a whole number of days, clamped to 1…365; anything else → 7.
    static func trialDays(from raw: String?) -> Int {
        guard let days = raw.flatMap({ Int($0.trimmingCharacters(in: .whitespaces)) }) else { return defaultTrialDays }
        return min(max(days, trialDaysRange.lowerBound), trialDaysRange.upperBound)
    }

    static func fromMainBundle() -> LicenseConfiguration {
        func value(_ key: String) -> String? {
            guard let raw = Bundle.main.object(forInfoDictionaryKey: key) as? String else { return nil }
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        let publicKey = value("NDLicensePublicKey")
            .flatMap { Data(base64Encoded: $0) }
            .flatMap { try? Curve25519.Signing.PublicKey(rawRepresentation: $0) }
        return LicenseConfiguration(
            apiBaseURL: value("NDLicenseAPIBaseURL").flatMap(URL.init(string:)),
            publicKey: publicKey,
            purchaseURL: value("NDPurchaseURL").flatMap(URL.init(string:)),
            trialDays: trialDays(from: value("NDTrialDays"))
        )
    }
}

// MARK: - Persisted vault

/// Everything licensing persists, stored as ONE Keychain item (one access prompt, atomic writes).
nonisolated struct LicenseVault: Codable, Equatable, Sendable {
    var trialStartedAt: Date
    /// HMAC over the start date + machine ID; detects edits and copying the item to another Mac.
    var trialSignature: String
    /// Latest time observed; makes the trial resistant to setting the clock back.
    var lastSeenAt: Date
    var activation: StoredActivation?
}

nonisolated struct StoredActivation: Codable, Equatable, Sendable {
    /// Kept so "Deactivate This Mac" can release the merchant seat.
    var licenseKey: String
    var receipt: SignedLicenseReceipt
}

/// Tamper-evidence for the trial record. The secret is embedded in the binary, so this deters
/// casual edits rather than a determined reverse engineer, which is the intended threat model.
nonisolated enum TrialSigner {
    private static let secret: [UInt8] = [
        0x7b, 0x6b, 0x47, 0x75, 0xb9, 0xc9, 0x06, 0x97, 0x5c, 0x55, 0xcd, 0x8b, 0x29, 0x32, 0x6b, 0x06,
        0xde, 0xdf, 0xe0, 0x21, 0x65, 0xb8, 0xca, 0x1b, 0x0c, 0xd2, 0x7f, 0x3b, 0xab, 0x4f, 0xa2, 0xee,
    ]

    private static func message(trialStart: Date, machineID: String) -> Data {
        Data("notchdeck.trial.v1|\(trialStart.timeIntervalSince1970)|\(machineID)".utf8)
    }

    static func signature(trialStart: Date, machineID: String) -> String {
        let code = HMAC<SHA256>.authenticationCode(
            for: message(trialStart: trialStart, machineID: machineID),
            using: SymmetricKey(data: secret)
        )
        return Data(code).base64EncodedString()
    }

    static func isValid(_ signature: String, trialStart: Date, machineID: String) -> Bool {
        guard let code = Data(base64Encoded: signature) else { return false }
        return HMAC<SHA256>.isValidAuthenticationCode(
            code,
            authenticating: message(trialStart: trialStart, machineID: machineID),
            using: SymmetricKey(data: secret)
        )
    }
}

// MARK: - Status

enum TrialExpiryReason: Equatable {
    case elapsed
    /// The trial record was edited, corrupted, or copied from another Mac.
    case tampered
}

struct LicenseSummary: Equatable {
    var edition: LicenseEdition
    var keyHint: String
    var activatedAt: Date
    var customerName: String?
}

enum LicenseStatus: Equatable {
    case checking
    case trial(daysRemaining: Int, endsAt: Date)
    case trialExpired(TrialExpiryReason)
    case licensed(LicenseSummary)
    /// The Keychain couldn't be read (e.g. access denied). Treated as unlocked: never punish
    /// a paying or trialing user for a storage hiccup.
    case storageUnavailable(message: String)
}

enum LicenseActivity: Equatable {
    case idle, activating, deactivating
}

// MARK: - Manager

/// 7-day trial + one-time license activation with offline Ed25519 receipt verification.
@Observable
final class LicenseManager {
    /// The standard trial length (tester builds may use a longer `configuration.trialDuration`).
    static let trialDuration = TimeInterval(LicenseConfiguration.defaultTrialDays) * 24 * 60 * 60
    static let vaultAccount = "license.vault"
    private static let lastSeenWriteInterval: TimeInterval = 60 * 60
    /// Small allowance for clock skew before a future-dated trial start counts as tampering.
    private static let clockSkewTolerance: TimeInterval = 10 * 60

    private(set) var status: LicenseStatus = .checking
    private(set) var activity: LicenseActivity = .idle
    private(set) var lastError: String?

    let configuration: LicenseConfiguration

    @ObservationIgnored private let store: SecureStore
    @ObservationIgnored private let client: LicenseActivating?
    @ObservationIgnored private let machineID: String
    @ObservationIgnored private let machineName: String
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private var refreshTask: Task<Void, Never>?
    @ObservationIgnored private var wakeObserver: NSObjectProtocol?

    init(
        store: SecureStore,
        configuration: LicenseConfiguration,
        client: LicenseActivating?,
        machineID: String,
        machineName: String,
        now: @escaping () -> Date = Date.init
    ) {
        self.store = store
        self.configuration = configuration
        self.client = client
        self.machineID = machineID
        self.machineName = machineName
        self.now = now
    }

    static func live(store: SecureStore) -> LicenseManager {
        let configuration = LicenseConfiguration.fromMainBundle()
        return LicenseManager(
            store: store,
            configuration: configuration,
            client: configuration.apiBaseURL.map { LicenseAPIClient(baseURL: $0) },
            machineID: HardwareIdentity.machineID(),
            machineName: HardwareIdentity.machineName
        )
    }

    // MARK: Derived state

    /// Whether the expanded notch modules are available.
    var isUnlocked: Bool {
        if case .trialExpired = status { return false }
        return true
    }

    var isLicensed: Bool {
        if case .licensed = status { return true }
        return false
    }

    /// Subtle, non-blocking badge text for Settings, e.g. "5 days left in free trial".
    var trialBadgeText: String? {
        switch status {
        case .trial(let days, _):
            days == 1 ? "1 day left in free trial" : "\(days) days left in free trial"
        case .trialExpired:
            "Free trial ended"
        default:
            nil
        }
    }

    // MARK: Lifecycle

    func start() {
        refresh()
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(60 * 60))
                self?.refresh()
            }
        }
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }

    func stop() {
        refreshTask?.cancel()
        if let wakeObserver { NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver) }
    }

    /// Re-evaluates trial / license state from the vault. Cheap; safe to call often.
    func refresh() {
        let current = now()
        let vault: LicenseVault
        do {
            if let existing = try loadVault() {
                vault = existing
            } else {
                vault = makeVault(startingAt: current)
                try saveVault(vault)
            }
        } catch VaultError.corrupted {
            // Never "repair" by starting a fresh trial; that would make resets trivial.
            status = .trialExpired(.tampered)
            return
        } catch {
            status = .storageUnavailable(message: error.localizedDescription)
            return
        }

        var updated = vault
        if current.timeIntervalSince(vault.lastSeenAt) > Self.lastSeenWriteInterval {
            updated.lastSeenAt = current
        }

        if let activation = vault.activation {
            do {
                let payload = try verify(activation)
                status = .licensed(LicenseSummary(
                    edition: payload.edition,
                    keyHint: payload.licenseKeyHint,
                    activatedAt: payload.issuedAt,
                    customerName: payload.customerName
                ))
            } catch {
                lastError = "The saved license couldn't be verified on this Mac. Please activate again."
                status = trialStatus(for: vault, at: max(current, vault.lastSeenAt))
            }
        } else {
            status = trialStatus(for: vault, at: max(current, vault.lastSeenAt))
        }

        if updated != vault { try? saveVault(updated) }
    }

    private func trialStatus(for vault: LicenseVault, at effectiveNow: Date) -> LicenseStatus {
        guard TrialSigner.isValid(vault.trialSignature, trialStart: vault.trialStartedAt, machineID: machineID),
              vault.trialStartedAt <= effectiveNow.addingTimeInterval(Self.clockSkewTolerance) else {
            return .trialExpired(.tampered)
        }
        let endsAt = vault.trialStartedAt.addingTimeInterval(configuration.trialDuration)
        let remaining = endsAt.timeIntervalSince(effectiveNow)
        guard remaining > 0 else { return .trialExpired(.elapsed) }
        return .trial(daysRemaining: Int((remaining / 86_400).rounded(.up)), endsAt: endsAt)
    }

    // MARK: Activation

    /// Activates `rawKey` with the license proxy and stores the verified receipt.
    @discardableResult
    func activate(licenseKey rawKey: String) async -> Bool {
        let key = Self.normalizedKey(rawKey)
        guard Self.isPlausibleKey(key) else {
            lastError = "That doesn't look like a license key. Check for typos and try again."
            return false
        }
        guard let client, let publicKey = configuration.publicKey else {
            lastError = "License activation isn't configured in this build."
            return false
        }

        activity = .activating
        lastError = nil
        defer { activity = .idle }

        do {
            let receipt = try await client.activate(licenseKey: key, machineID: machineID, machineName: machineName)
            let payload = try ReceiptVerifier(publicKey: publicKey).verify(receipt, machineID: machineID)
            guard payload.licenseKeyHint.caseInsensitiveCompare(String(key.suffix(4))) == .orderedSame else {
                throw ReceiptVerificationError.keyMismatch
            }
            var vault = try loadVault() ?? makeVault(startingAt: now())
            vault.activation = StoredActivation(licenseKey: key, receipt: receipt)
            try saveVault(vault)
            refresh()
            return true
        } catch {
            lastError = Self.message(for: error)
            return false
        }
    }

    /// Releases this Mac's activation on the server so the license can move to another Mac.
    @discardableResult
    func deactivate() async -> Bool {
        guard var vault = try? loadVault(), let activation = vault.activation else { return false }
        guard let client else {
            lastError = "License activation isn't configured in this build."
            return false
        }
        guard let payloadData = Data(base64Encoded: activation.receipt.payload),
              let payload = try? LicensePayload.decode(from: payloadData) else {
            // An unreadable receipt holds no seat we can name; just forget it locally.
            vault.activation = nil
            try? saveVault(vault)
            refresh()
            return true
        }

        activity = .deactivating
        lastError = nil
        defer { activity = .idle }

        do {
            try await client.deactivate(licenseKey: activation.licenseKey, machineID: machineID, instanceID: payload.instanceID)
            vault.activation = nil
            try saveVault(vault)
            refresh()
            return true
        } catch {
            lastError = Self.message(for: error)
            return false
        }
    }

    func clearError() {
        lastError = nil
    }

    // MARK: Helpers

    private func verify(_ activation: StoredActivation) throws -> LicensePayload {
        guard let publicKey = configuration.publicKey else { throw ReceiptVerificationError.invalidSignature }
        return try ReceiptVerifier(publicKey: publicKey).verify(activation.receipt, machineID: machineID)
    }

    private func makeVault(startingAt date: Date) -> LicenseVault {
        LicenseVault(
            trialStartedAt: date,
            trialSignature: TrialSigner.signature(trialStart: date, machineID: machineID),
            lastSeenAt: date,
            activation: nil
        )
    }

    private enum VaultError: Error { case corrupted }

    private func loadVault() throws -> LicenseVault? {
        guard let data = try store.data(for: Self.vaultAccount) else { return nil }
        guard let vault = try? JSONDecoder().decode(LicenseVault.self, from: data) else { throw VaultError.corrupted }
        return vault
    }

    private func saveVault(_ vault: LicenseVault) throws {
        try store.setData(JSONEncoder().encode(vault), for: Self.vaultAccount)
    }

    static func normalizedKey(_ raw: String) -> String {
        raw.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Accepts merchant formats (XXXX-XXXX-…, UUIDs) and master keys: 8–128 letters, digits, dashes.
    static func isPlausibleKey(_ key: String) -> Bool {
        (8...128).contains(key.count) && key.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }
    }

    private static func message(for error: Error) -> String {
        switch error {
        case let error as LicenseAPIError:
            return error.errorDescription ?? "Activation failed."
        case is ReceiptVerificationError:
            return "The license server's response couldn't be verified. Please contact support."
        case let error as KeychainError:
            return "Couldn't save the license to the Keychain. \(error.errorDescription ?? "")"
        default:
            return error.localizedDescription
        }
    }
}
