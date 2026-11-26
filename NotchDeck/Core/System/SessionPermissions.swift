import Foundation
import OSLog

/// Makes privacy permissions last for one run of NotchDeck.
///
/// macOS stores privacy approvals (TCC) permanently and has no "allow until quit" option, so
/// NotchDeck resets *its own* approvals with `tccutil` at launch and again at quit. The result:
/// permissions granted while it runs stay on until it quits, and the next launch asks again.
/// Resetting your own app's approvals needs no admin rights.
nonisolated enum SessionPermissions {
    /// TCC services NotchDeck uses (or will, in later phases).
    enum Service: String, CaseIterable, Sendable {
        case appleEvents = "AppleEvents"   // control Music / Spotify
        case calendar = "Calendar"         // EventKit events
        case reminders = "Reminders"       // EventKit reminders (later)
        case camera = "Camera"             // Camera Mirror (Phase 6)
    }

    private static let logger = Logger(subsystem: "com.notchdeck.NotchDeck", category: "Permissions")

    /// How often a module silently re-checks a permission it doesn't have yet (Music/Spotify
    /// Automation, Calendars), so allowing it in System Settings takes effect without a relaunch.
    static let recheckInterval: Duration = .seconds(15)

    /// Forgets every approval NotchDeck holds, so macOS asks again on next use.
    static func resetAll(bundleIdentifier: String? = Bundle.main.bundleIdentifier) {
        guard let bundleIdentifier else { return }
        for service in Service.allCases {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
            process.arguments = ["reset", service.rawValue, bundleIdentifier]
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            do {
                try process.run()
                process.waitUntilExit()
                logger.notice("tccutil reset \(service.rawValue, privacy: .public) → exit \(process.terminationStatus)")
            } catch {
                logger.error("tccutil failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }
}
