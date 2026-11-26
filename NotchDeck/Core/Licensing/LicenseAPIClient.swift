import Foundation

/// Talks to the license proxy (see Server/license-proxy). Abstracted for tests.
protocol LicenseActivating {
    func activate(licenseKey: String, machineID: String, machineName: String) async throws -> SignedLicenseReceipt
    func deactivate(licenseKey: String, machineID: String, instanceID: String) async throws
}

enum LicenseAPIError: LocalizedError, Equatable {
    /// The server rejected the request with a human-readable reason.
    case rejected(message: String, statusCode: Int)
    case invalidResponse
    case unreachable

    var errorDescription: String? {
        switch self {
        case .rejected(let message, _): message
        case .invalidResponse: "The license server sent an unexpected response."
        case .unreachable: "Couldn't reach the license server. Check your connection and try again."
        }
    }
}

struct LicenseAPIClient: LicenseActivating {
    let baseURL: URL
    var session: URLSession = .shared

    private struct ActivateRequest: Encodable {
        let license_key: String
        let machine_id: String
        let machine_name: String
    }

    private struct DeactivateRequest: Encodable {
        let license_key: String
        let machine_id: String
        let instance_id: String
    }

    private struct ActivateResponse: Decodable { let receipt: SignedLicenseReceipt }
    private struct DeactivateResponse: Decodable { let deactivated: Bool }
    private struct ErrorResponse: Decodable { let error: String }

    func activate(licenseKey: String, machineID: String, machineName: String) async throws -> SignedLicenseReceipt {
        let response: ActivateResponse = try await post(
            "v1/licenses/activate",
            ActivateRequest(license_key: licenseKey, machine_id: machineID, machine_name: machineName)
        )
        return response.receipt
    }

    func deactivate(licenseKey: String, machineID: String, instanceID: String) async throws {
        let response: DeactivateResponse = try await post(
            "v1/licenses/deactivate",
            DeactivateRequest(license_key: licenseKey, machine_id: machineID, instance_id: instanceID)
        )
        guard response.deactivated else { throw LicenseAPIError.invalidResponse }
    }

    private func post<Body: Encodable, Response: Decodable>(_ path: String, _ body: Body) async throws -> Response {
        var request = URLRequest(url: baseURL.appending(path: path))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 20
        request.httpBody = try JSONEncoder().encode(body)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw LicenseAPIError.unreachable
        }
        guard let http = response as? HTTPURLResponse else { throw LicenseAPIError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else {
            let message = (try? JSONDecoder().decode(ErrorResponse.self, from: data))?.error
                ?? "The license server returned an error (\(http.statusCode))."
            throw LicenseAPIError.rejected(message: message, statusCode: http.statusCode)
        }
        do {
            return try JSONDecoder().decode(Response.self, from: data)
        } catch {
            throw LicenseAPIError.invalidResponse
        }
    }
}
