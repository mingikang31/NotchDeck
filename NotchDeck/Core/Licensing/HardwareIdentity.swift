import CryptoKit
import Foundation
import IOKit

/// Stable per-Mac identity used to bind the trial record and license activations.
nonisolated enum HardwareIdentity {
    /// The hardware `IOPlatformUUID` (stable across OS reinstalls).
    static func platformUUID() -> String? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPlatformExpertDevice"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        let property = IORegistryEntryCreateCFProperty(service, kIOPlatformUUIDKey as CFString, kCFAllocatorDefault, 0)
        return property?.takeRetainedValue() as? String
    }

    /// Salted SHA-256 of the platform UUID. This, never the raw UUID, leaves the Mac.
    static func machineID(platformUUID: String? = platformUUID()) -> String {
        let source = "notchdeck.machine.v1:" + (platformUUID ?? "unknown-platform-uuid")
        return SHA256.hash(data: Data(source.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    static var machineName: String {
        Host.current().localizedName ?? "Mac"
    }
}
