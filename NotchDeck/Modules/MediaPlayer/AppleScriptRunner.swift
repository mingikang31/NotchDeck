import Foundation

nonisolated struct AppleScriptError: Error, Equatable, Sendable {
    let number: Int
    let message: String

    /// errAEEventNotPermitted: the user hasn't allowed NotchDeck to control the target app.
    var isAutomationDenied: Bool { number == -1743 }
}

/// Executes AppleScript off the main thread.
///
/// Apple events are synchronous and a busy target app can stall a call for seconds, so scripts
/// run off the main thread on a serial queue per runner, each with its own NSAppleScript
/// instances (never shared across threads). Player scripts use `shared`; consent requests,
/// which can wait minutes for the user, use `consent` so they don't block playback updates.
/// Compiled scripts are cached by source.
nonisolated final class AppleScriptRunner: @unchecked Sendable {
    static let shared = AppleScriptRunner()
    /// Separate queue for consent requests, which can wait minutes for the user's answer
    /// without holding up regular player scripts.
    static let consent = AppleScriptRunner(label: "com.notchdeck.applescript.consent")

    init(label: String = "com.notchdeck.applescript") {
        queue = DispatchQueue(label: label, qos: .userInitiated)
    }

    private let queue: DispatchQueue
    /// Only touched on `queue`.
    private var compiled: [String: NSAppleScript] = [:]

    func run<T: Sendable>(
        _ source: String,
        transform: @escaping @Sendable (NSAppleEventDescriptor) -> T?
    ) async throws -> T? {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                let script: NSAppleScript
                if let cached = self.compiled[source] {
                    script = cached
                } else if let fresh = NSAppleScript(source: source) {
                    self.compiled[source] = fresh
                    script = fresh
                } else {
                    continuation.resume(throwing: AppleScriptError(number: 0, message: "Couldn't create script"))
                    return
                }

                var errorInfo: NSDictionary?
                let result = script.executeAndReturnError(&errorInfo)
                if let errorInfo {
                    continuation.resume(throwing: AppleScriptError(
                        number: errorInfo[NSAppleScript.errorNumber] as? Int ?? 0,
                        message: errorInfo[NSAppleScript.errorMessage] as? String ?? "AppleScript error"
                    ))
                } else {
                    continuation.resume(returning: transform(result))
                }
            }
        }
    }

    /// Runs a script whose result is ignored (transport commands).
    func run(_ source: String) async throws {
        _ = try await run(source) { _ in true }
    }
}

nonisolated extension NSAppleEventDescriptor {
    /// Items of an AppleScript list (1-based in the descriptor API).
    var listItems: [NSAppleEventDescriptor] {
        guard numberOfItems > 0 else { return [] }
        return (1...numberOfItems).compactMap { atIndex($0) }
    }
}
