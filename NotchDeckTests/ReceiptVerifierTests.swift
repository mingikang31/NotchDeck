import CryptoKit
import Foundation
import Testing
@testable import NotchDeck

private final class BundleToken {}

struct ReceiptVerifierTests {
    /// The machine ID the fixture was issued for (see Server/license-proxy, MERCHANT=mock).
    private let fixtureMachineID = String(repeating: "a", count: 64)

    private func fixtureReceipt() throws -> SignedLicenseReceipt {
        let bundle = Bundle(for: BundleToken.self)
        let url = try #require(
            bundle.url(forResource: "worker-dev-receipt", withExtension: "json")
                ?? bundle.url(forResource: "worker-dev-receipt", withExtension: "json", subdirectory: "Fixtures")
        )
        struct Wrapper: Decodable { let receipt: SignedLicenseReceipt }
        return try JSONDecoder().decode(Wrapper.self, from: Data(contentsOf: url)).receipt
    }

    /// Cross-implementation check: a receipt signed by the JS Worker (WebCrypto Ed25519) verifies
    /// with CryptoKit using the DEV public key that the xcconfig injects into the app's Info.plist.
    @Test func workerSignedReceiptVerifiesWithBundledDevKey() throws {
        let publicKey = try #require(LicenseConfiguration.fromMainBundle().publicKey, "Debug Info.plist should carry the DEV public key")
        let payload = try ReceiptVerifier(publicKey: publicKey).verify(fixtureReceipt(), machineID: fixtureMachineID)
        #expect(payload.edition == .standard)
        #expect(payload.licenseKeyHint == "CCCC")
        #expect(payload.product == "notchdeck")
        #expect(payload.instanceID.hasPrefix("mock-"))
    }

    @Test func alteredPayloadFailsVerification() throws {
        let publicKey = try #require(LicenseConfiguration.fromMainBundle().publicKey)
        var receipt = try fixtureReceipt()
        var payload = try #require(Data(base64Encoded: receipt.payload))
        payload[payload.count / 2] ^= 0x01
        receipt.payload = payload.base64EncodedString()
        #expect(throws: ReceiptVerificationError.invalidSignature) {
            try ReceiptVerifier(publicKey: publicKey).verify(receipt, machineID: fixtureMachineID)
        }
    }

    @Test func receiptIsBoundToItsMachine() throws {
        let publicKey = try #require(LicenseConfiguration.fromMainBundle().publicKey)
        #expect(throws: ReceiptVerificationError.wrongMachine) {
            try ReceiptVerifier(publicKey: publicKey).verify(fixtureReceipt(), machineID: "another-mac")
        }
    }

    @Test func wrongProductIsRejected() throws {
        let server = MockLicenseServer()
        let receipt = try server.makeReceipt(edition: "standard", hint: "CCCC", machineID: "m", instanceID: "i", product: "otherapp")
        #expect(throws: ReceiptVerificationError.wrongProduct) {
            try ReceiptVerifier(publicKey: server.publicKey).verify(receipt, machineID: "m")
        }
    }

    @Test func garbageIsMalformed() {
        let receipt = SignedLicenseReceipt(payload: "not base64!", signature: "also not")
        #expect(throws: ReceiptVerificationError.malformed) {
            try ReceiptVerifier(publicKey: Curve25519.Signing.PrivateKey().publicKey).verify(receipt, machineID: "m")
        }
    }

    @Test func machineIDIsAStableSaltedHash() {
        let id = HardwareIdentity.machineID(platformUUID: "00000000-1111-2222-3333-444444444444")
        #expect(id.count == 64)
        #expect(id == HardwareIdentity.machineID(platformUUID: "00000000-1111-2222-3333-444444444444"))
        #expect(!id.contains("1111"))
        #expect(HardwareIdentity.platformUUID() != nil)
    }
}

/// Opt-in end-to-end test against a running proxy:
///   node Server/license-proxy/dev-server.mjs
///   TEST_RUNNER_NOTCHDECK_LICENSE_SERVER=http://127.0.0.1:8787 xcodebuild test …
/// Set TEST_RUNNER_NOTCHDECK_MASTER_KEY too, to also exercise the master key.
struct LicenseServerIntegrationTests {
    private nonisolated static let serverURL = ProcessInfo.processInfo.environment["NOTCHDECK_LICENSE_SERVER"].flatMap { URL(string: $0) }
    private nonisolated static let masterKey = ProcessInfo.processInfo.environment["NOTCHDECK_MASTER_KEY"]

    @Test(.enabled(if: serverURL != nil, "Set NOTCHDECK_LICENSE_SERVER to run"))
    func activateVerifyAndDeactivateAgainstLiveProxy() async throws {
        let client = LicenseAPIClient(baseURL: try #require(Self.serverURL))
        let publicKey = try #require(LicenseConfiguration.fromMainBundle().publicKey)
        let machineID = HardwareIdentity.machineID(platformUUID: "integration-test-mac")

        let receipt = try await client.activate(licenseKey: "TEST-INTG-1234-WXYZ", machineID: machineID, machineName: "CI")
        let payload = try ReceiptVerifier(publicKey: publicKey).verify(receipt, machineID: machineID)
        #expect(payload.edition == .standard)
        #expect(payload.licenseKeyHint == "WXYZ")
        try await client.deactivate(licenseKey: "TEST-INTG-1234-WXYZ", machineID: machineID, instanceID: payload.instanceID)

        await #expect(throws: LicenseAPIError.self) {
            _ = try await client.activate(licenseKey: "NOT-A-REAL-KEY-0000", machineID: machineID, machineName: "CI")
        }
    }

    @Test(.enabled(if: serverURL != nil && masterKey != nil, "Set NOTCHDECK_LICENSE_SERVER and NOTCHDECK_MASTER_KEY to run"))
    func masterKeyActivatesThroughLiveProxy() async throws {
        let client = LicenseAPIClient(baseURL: try #require(Self.serverURL))
        let publicKey = try #require(LicenseConfiguration.fromMainBundle().publicKey)
        let masterKey = try #require(Self.masterKey)
        let machineID = HardwareIdentity.machineID(platformUUID: "integration-test-mac")

        let receipt = try await client.activate(licenseKey: masterKey, machineID: machineID, machineName: "CI")
        let payload = try ReceiptVerifier(publicKey: publicKey).verify(receipt, machineID: machineID)
        #expect(payload.edition == .master)

        let decoded = String(decoding: try #require(Data(base64Encoded: receipt.payload)), as: UTF8.self)
        #expect(!decoded.uppercased().contains(masterKey.uppercased()), "Receipt must never contain the master key")
    }
}
