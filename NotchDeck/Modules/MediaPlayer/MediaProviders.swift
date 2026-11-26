import AppKit
import Foundation

nonisolated enum MediaSource: String, CaseIterable, Sendable {
    case music, spotify

    var bundleIdentifier: String {
        switch self {
        case .music: "com.apple.Music"
        case .spotify: "com.spotify.client"
        }
    }

    var displayName: String {
        switch self {
        case .music: "Music"
        case .spotify: "Spotify"
        }
    }

    /// Distributed notification the app posts whenever playback or the track changes.
    var playerInfoNotification: Notification.Name {
        switch self {
        case .music: Notification.Name("com.apple.Music.playerInfo")
        case .spotify: Notification.Name("com.spotify.client.PlaybackStateChanged")
        }
    }

    var isRunning: Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier).isEmpty
    }
}

/// Whether macOS lets NotchDeck send Apple events to a player (Privacy → Automation).
nonisolated enum AutomationConsent: Equatable, Sendable {
    case granted
    /// The user said no (or it's switched off in System Settings → Automation).
    case denied
    /// Nobody has answered yet.
    case needsConsent
    case notRunning

    /// Silent status check (`askUserIfNeeded` must stay false: with true, this API blocked forever
    /// on macOS 27 without ever showing a prompt). Blocks briefly; call off the main thread.
    static func determine(bundleIdentifier: String, askUserIfNeeded: Bool = false) -> AutomationConsent {
        let target = NSAppleEventDescriptor(bundleIdentifier: bundleIdentifier)
        guard let address = target.aeDesc else { return .notRunning }
        let status = AEDeterminePermissionToAutomateTarget(address, AEEventClass(typeWildCard), AEEventID(typeWildCard), askUserIfNeeded)
        switch status {
        case noErr: return .granted
        case OSStatus(procNotFound): return .notRunning
        case -1744: return .needsConsent // errAEEventWouldRequireUserConsent (asked silently)
        default: return .denied          // errAEEventNotPermitted (-1743)
        }
    }
}

nonisolated enum PlaybackState: String, Sendable {
    case playing, paused, stopped
}

/// One reading of a player's state.
nonisolated struct MediaSnapshot: Equatable, Sendable {
    var source: MediaSource
    var state: PlaybackState
    var trackID: String
    var title: String
    var artist: String
    var album: String
    var duration: TimeInterval
    var position: TimeInterval
    /// Spotify exposes artwork as a URL; Music returns raw image data via a separate call.
    var artworkURL: URL?

    /// Parses the list returned by the snapshot scripts:
    /// `{state, id, name, artist, album, durationSeconds, positionSeconds[, artworkURL]}` or `{"stopped"}`.
    static func parse(_ descriptor: NSAppleEventDescriptor, source: MediaSource) -> MediaSnapshot? {
        let items = descriptor.listItems
        guard let stateString = items.first?.stringValue else { return nil }
        let state: PlaybackState = switch stateString {
        case "playing", "fast forwarding", "rewinding": .playing
        case "paused": .paused
        default: .stopped
        }
        guard state != .stopped, items.count >= 7 else { return nil }
        return MediaSnapshot(
            source: source,
            state: state,
            trackID: items[1].stringValue ?? "",
            title: items[2].stringValue ?? "",
            artist: items[3].stringValue ?? "",
            album: items[4].stringValue ?? "",
            duration: items[5].doubleValue,
            position: items[6].doubleValue,
            artworkURL: items.count > 7 ? items[7].stringValue.flatMap { URL(string: $0) } : nil
        )
    }
}

nonisolated enum MediaCommand: Equatable, Sendable {
    case playPause, next, previous
    case seek(TimeInterval)
}

/// Reads and controls one player app via AppleScript. Every script targets the app by bundle ID
/// and callers check `isRunning` first, so NotchDeck never launches a player by itself.
nonisolated struct MediaProvider: Sendable {
    let source: MediaSource
    var runner: AppleScriptRunner = .shared

    private var target: String { "application id \"\(source.bundleIdentifier)\"" }

    private var snapshotScript: String {
        let duration = source == .spotify ? "(duration of t) / 1000" : "duration of t"
        let artwork = source == .spotify ? ", artwork url of t" : ""
        let trackID = source == .spotify ? "id of t" : "(persistent ID of t) as string"
        return """
        with timeout of 3 seconds
            tell \(target)
                set s to player state as string
                if s is "stopped" then return {s}
                set t to current track
                return {s, \(trackID), name of t, artist of t, album of t, \(duration), player position\(artwork)}
            end tell
        end timeout
        """
    }

    func snapshot() async throws -> MediaSnapshot? {
        guard source.isRunning else { return nil }
        let source = source
        return try await runner.run(snapshotScript) { MediaSnapshot.parse($0, source: source) }
    }

    /// Raw artwork bytes for the current track (Music only; Spotify uses `artworkURL`).
    func artworkData() async -> Data? {
        guard source == .music, source.isRunning else { return nil }
        let script = """
        with timeout of 3 seconds
            tell \(target) to get data of artwork 1 of current track
        end timeout
        """
        return try? await runner.run(script) { $0.data.isEmpty ? nil : $0.data }
    }

    /// Triggers the macOS "control <player>" prompt with a harmless read, and waits up to
    /// 10 minutes for the answer. Sending a real Apple event is what reliably shows the prompt;
    /// the long timeout is essential, because a short one expiring while the prompt is open makes
    /// macOS record "denied".
    func requestConsent() async -> AutomationConsent {
        guard source.isRunning else { return .notRunning }
        let script = """
        with timeout of 600 seconds
            tell \(target) to get player state
        end timeout
        """
        do {
            try await AppleScriptRunner.consent.run(script)
            return .granted
        } catch let error as AppleScriptError {
            switch error.number {
            case -1743: return .denied            // errAEEventNotPermitted: user said no
            case -600, -609: return .notRunning   // player quit meanwhile
            case -1712: return .needsConsent      // still unanswered after 10 minutes
            default: return .granted              // the event got through; it failed for another reason
            }
        } catch {
            return .needsConsent
        }
    }

    func send(_ command: MediaCommand) async throws {
        guard source.isRunning else { return }
        let verb = switch command {
        case .playPause: "playpause"
        case .next: "next track"
        case .previous: "previous track"
        case .seek(let seconds): "set player position to \(max(0, seconds))"
        }
        try await runner.run("tell \(target) to \(verb)")
    }
}
