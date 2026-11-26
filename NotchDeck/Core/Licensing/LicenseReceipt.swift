import CryptoKit
import Foundation

nonisolated enum LicenseEdition: String, Codable, Sendable {
    case standard
    /// Issued for the master key: unlimited activations, no merchant seat.
    case master
}

/// Wire format returned by the license proxy: base64 JSON payload + base64 Ed25519 signature.
nonisolated struct SignedLicenseReceipt: Codable, Equatable, Sendable {
    var payload: String
    var signature: String
}

/// The signed claims. Contains only a hint of the key, never the key itself.
nonisolated struct LicensePayload: Codable, Equatable, Sendable {
    var version: Int
    var product: String
    var edition: LicenseEdition
    var licenseKeyHint: String
    var machineID: String
    var instanceID: String
    var issuedAt: Date
    var customerName: String?

    enum CodingKeys: String, CodingKey {
        case version = "v"
        case product
        case edition
        case licenseKeyHint = "license_key_hint"
        case machineID = "machine_id"
        case instanceID = "instance_id"
        case issuedAt = "issued_at"
        case customerName = "customer_name"
    }

    static func decode(from data: Data) throws -> LicensePayload {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let string = try decoder.singleValueContainer().decode(String.self)
            if let date = try? Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse(string) { return date }
            if let date = try? Date.ISO8601FormatStyle().parse(string) { return date }
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Bad date \(string)"))
        }
        return try decoder.decode(LicensePayload.self, from: data)
    }
}

nonisolated enum ReceiptVerificationError: Error, Equatable {
    case malformed
    case invalidSignature
    case unsupportedVersion(Int)
    case wrongProduct
    case wrongMachine
    case keyMismatch
}

/// Offline verification of receipts against the public key embedded in the app.
nonisolated struct ReceiptVerifier: Sendable {
    static let supportedVersion = 1
    let publicKey: Curve25519.Signing.PublicKey
    var productID = "notchdeck"

    func verify(_ receipt: SignedLicenseReceipt, machineID: String) throws -> LicensePayload {
        guard let payloadData = Data(base64Encoded: receipt.payload),
              let signature = Data(base64Encoded: receipt.signature) else {
            throw ReceiptVerificationError.malformed
        }
        guard publicKey.isValidSignature(signature, for: payloadData) else {
            throw ReceiptVerificationError.invalidSignature
        }
        let payload: LicensePayload
        do {
            payload = try LicensePayload.decode(from: payloadData)
        } catch {
            throw ReceiptVerificationError.malformed
        }
        guard payload.version == Self.supportedVersion else {
            throw ReceiptVerificationError.unsupportedVersion(payload.version)
        }
        guard payload.product == productID else { throw ReceiptVerificationError.wrongProduct }
        guard payload.machineID == machineID else { throw ReceiptVerificationError.wrongMachine }
        return payload
    }
}
