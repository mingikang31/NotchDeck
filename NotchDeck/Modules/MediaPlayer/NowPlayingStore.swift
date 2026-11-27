import AppKit
import CoreAudio
import Observation
import OSLog
import SwiftUI

/// Now Playing state for Music and Spotify.
///
/// Event-driven: both apps post a distributed notification on every play/pause/track change,
/// which triggers a snapshot. While something plays, a slow resync keeps the scrub position
/// honest; between readings the position is interpolated, so nothing polls every second.
@Observable
final class NowPlayingStore {
    private(set) var snapshot: MediaSnapshot?
    /// When `snapshot.position` was read; used to interpolate the live position.
    private(set) var snapshotDate = Date()
    private(set) var artwork: NSImage?
    /// `[vibrant, average]` from the artwork, or empty.
    private(set) var palette: [Color] = []
    private(set) var outputDevices: [AudioOutputDevice] = []
    private(set) var currentOutputDeviceID: AudioDeviceID?
    /// A running player NotchDeck may not control yet; drives the Media tab's permission card.
    private(set) var consentIssue: ConsentIssue?

    struct ConsentIssue: Equatable {
        var source: MediaSource
        /// A request is open: macOS should be showing (or holding back) its prompt.
        var isWaitingForAnswer: Bool
        var isDenied: Bool
    }

    var isPlaying: Bool { snapshot?.state == .playing }

    @ObservationIgnored private var providers: [MediaSource: MediaProvider] = Dictionary(
        uniqueKeysWithValues: MediaSource.allCases.map { ($0, MediaProvider(source: $0)) }
    )
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private var resyncTask: Task<Void, Never>?
    @ObservationIgnored private var artworkTrackID: String?
    @ObservationIgnored private var lastActiveSource: MediaSource?
    /// Automation consent per player for this run.
    @ObservationIgnored private var consent: [MediaSource: AutomationConsent] = [:]
    /// Players with an open consent request (a blocking call waiting for the user's answer).
    @ObservationIgnored private var consentRequests: Set<MediaSource> = []
    /// Polls silently while a running player lacks consent, so allowing it in System Settings
    /// (or answering a late prompt) takes effect within seconds, no relaunch needed.
    @ObservationIgnored private var consentWatchTask: Task<Void, Never>?
    @ObservationIgnored private(set) var isActive = false
    @ObservationIgnored private let logger = Logger(subsystem: "com.notchdeck.NotchDeck", category: "Media")

    private static let resyncInterval: Duration = .seconds(10)

    // MARK: Lifecycle

    /// Started/stopped as the Media module is enabled/disabled (and with the license gate).
    func setActive(_ active: Bool) {
        guard active != isActive else { return }
        isActive = active
        active ? start() : stop()
    }

    private func start() {
        let distributed = DistributedNotificationCenter.default()
        for source in MediaSource.allCases {
            observers.append(distributed.addObserver(forName: source.playerInfoNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.lastActiveSource = source
                    self?.refreshSoon()
                }
            })
        }
        let workspace = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            observers.append(workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refreshSoon() }
            })
        }
        refreshSoon()
        refreshOutputDevices()
        consentWatchTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: SessionPermissions.recheckInterval)
                await self?.recheckConsent()
            }
        }
    }

    private func stop() {
        observers.forEach {
            DistributedNotificationCenter.default().removeObserver($0)
            NSWorkspace.shared.notificationCenter.removeObserver($0)
        }
        observers.removeAll()
        resyncTask?.cancel()
        resyncTask = nil
        consentWatchTask?.cancel()
        consentWatchTask = nil
        consentIssue = nil
        snapshot = nil
        artwork = nil
        palette = []
        artworkTrackID = nil
    }

    // MARK: Reading

    /// Interpolated playback position at `date` (clamped to the track length).
    func position(at date: Date) -> TimeInterval {
        guard let snapshot else { return 0 }
        let elapsed = snapshot.state == .playing ? date.timeIntervalSince(snapshotDate) : 0
        return min(max(0, snapshot.position + elapsed), max(snapshot.duration, 0))
    }

    private func refreshSoon() {
        Task { await refresh() }
    }

    func refresh() async {
        guard isActive else { return }
        var readings: [MediaSnapshot] = []
        for source in MediaSource.allCases where source.isRunning {
            guard hasConsent(for: source) else { continue }
            do {
                if let reading = try await providers[source]?.snapshot() { readings.append(reading) }
            } catch let error as AppleScriptError where error.isAutomationDenied {
                consent[source] = .denied
            } catch {
                logger.debug("Snapshot failed for \(source.rawValue, privacy: .public): \(String(describing: error), privacy: .public)")
            }
        }
        updateConsentIssue()
        apply(Self.preferred(readings, lastActive: lastActiveSource))
    }

    /// True once the user has allowed NotchDeck to control `source`. Otherwise starts one consent
    /// request (if none is open and the user hasn't already said no) and returns false; scripts
    /// are never sent without consent, because their timeout would auto-deny an open prompt.
    private func hasConsent(for source: MediaSource) -> Bool {
        if consent[source] == .granted { return true }
        if consent[source] != .denied { requestConsent(for: source, bringToFront: false) }
        return false
    }

    /// Opens one consent request (the macOS prompt); it waits up to 10 minutes for the answer.
    private func requestConsent(for source: MediaSource, bringToFront: Bool) {
        if bringToFront { NSApp.activate() }
        // Never stack prompts: if one is already open, bringing NotchDeck forward is all we do.
        guard !consentRequests.contains(source), let provider = providers[source] else { return }
        consentRequests.insert(source)
        updateConsentIssue()
        logger.notice("Requesting Automation consent for \(source.rawValue, privacy: .public) (frontmost: \(bringToFront))")
        Task {
            let result = await provider.requestConsent()
            logger.notice("Automation consent for \(source.rawValue, privacy: .public): \(String(describing: result), privacy: .public)")
            consentRequests.remove(source)
            apply(consent: result, for: source)
        }
    }

    /// User tapped "Ask Again" in the Media tab.
    func askForConsentAgain(_ source: MediaSource) {
        if consent[source] == .denied { consent[source] = nil }
        requestConsent(for: source, bringToFront: true)
    }

    /// Silent check (never prompts) for every running player still lacking consent.
    private func recheckConsent() async {
        for source in MediaSource.allCases where source.isRunning && consent[source] != .granted {
            let result = await Self.silentConsentCheck(for: source)
            // Don't let a silent "not answered yet" overwrite an explicit "denied".
            if result == .needsConsent, consent[source] == .denied { continue }
            apply(consent: result, for: source)
        }
        updateConsentIssue()
    }

    private func apply(consent result: AutomationConsent, for source: MediaSource) {
        let wasGranted = consent[source] == .granted
        consent[source] = result == .notRunning ? nil : result
        updateConsentIssue()
        if result == .granted, !wasGranted { refreshSoon() }
    }

    private func updateConsentIssue() {
        guard isActive else { consentIssue = nil; return }
        consentIssue = MediaSource.allCases
            .first { $0.isRunning && consent[$0] != .granted }
            .map { ConsentIssue(source: $0, isWaitingForAnswer: consentRequests.contains($0), isDenied: consent[$0] == .denied) }
    }

    /// Non-prompting status check, guarded by a 2 s deadline so a wedged system call can never
    /// stall the watcher.
    nonisolated private static func silentConsentCheck(for source: MediaSource) async -> AutomationConsent {
        let bundleIdentifier = source.bundleIdentifier
        return await withCheckedContinuation { continuation in
            let once = ResumeOnce(continuation)
            DispatchQueue.global(qos: .utility).async {
                once.resume(AutomationConsent.determine(bundleIdentifier: bundleIdentifier))
            }
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 2) {
                once.resume(.needsConsent)
            }
        }
    }

    /// Picks what to show when both players have a track: whichever is playing, then the one
    /// that most recently announced a change.
    static func preferred(_ readings: [MediaSnapshot], lastActive: MediaSource?) -> MediaSnapshot? {
        readings.first { $0.state == .playing && $0.source == lastActive }
            ?? readings.first { $0.state == .playing }
            ?? readings.first { $0.source == lastActive }
            ?? readings.first
    }

    private func apply(_ reading: MediaSnapshot?) {
        snapshot = reading
        snapshotDate = reading?.readAt ?? Date()
        scheduleResync()
        guard let reading else {
            artwork = nil
            palette = []
            artworkTrackID = nil
            return
        }
        if reading.trackID != artworkTrackID {
            artworkTrackID = reading.trackID
            Task { await loadArtwork(for: reading) }
        }
    }

    private func scheduleResync() {
        resyncTask?.cancel()
        guard isPlaying else { return }
        resyncTask = Task { [weak self] in
            try? await Task.sleep(for: Self.resyncInterval)
            guard !Task.isCancelled else { return }
            await self?.refresh()
        }
    }

    private func loadArtwork(for reading: MediaSnapshot) async {
        var data: Data?
        if let url = reading.artworkURL, url.scheme == "https" {
            data = try? await URLSession.shared.data(from: url).0
        } else {
            data = await providers[reading.source]?.artworkData()
        }
        // Ignore results for a track that's no longer current.
        guard reading.trackID == artworkTrackID else { return }
        let image = data.flatMap(NSImage.init(data:))
        artwork = image
        if let cgImage = image?.cgImage(forProposedRect: nil, context: nil, hints: nil) {
            palette = ArtworkPalette.extract(from: cgImage).map(\.color)
        } else {
            palette = []
        }
    }

    // MARK: Control

    func perform(_ command: MediaCommand) {
        guard let source = snapshot?.source ?? MediaSource.allCases.first(where: \.isRunning),
              let provider = providers[source] else { return }
        if case .seek(let seconds) = command, var current = snapshot {
            // Optimistic update so the scrubber doesn't snap back while the event round-trips.
            current.position = seconds
            snapshot = current
            snapshotDate = Date()
        }
        Task {
            guard hasConsent(for: source) else { return }
            do {
                try await provider.send(command)
            } catch let error as AppleScriptError where error.isAutomationDenied {
                consent[source] = .denied
                updateConsentIssue()
            } catch {
                logger.debug("Command failed: \(String(describing: error), privacy: .public)")
            }
            try? await Task.sleep(for: .milliseconds(250))
            await refresh()
        }
    }

    func openAutomationSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation") {
            NSWorkspace.shared.open(url)
        }
    }

    func launch(_ source: MediaSource) {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: source.bundleIdentifier) else { return }
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
    }

    func isInstalled(_ source: MediaSource) -> Bool {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: source.bundleIdentifier) != nil
    }

    // MARK: Output devices

    func refreshOutputDevices() {
        outputDevices = AudioOutputDevices.all()
        currentOutputDeviceID = AudioOutputDevices.defaultDeviceID()
    }

    func selectOutputDevice(_ device: AudioOutputDevice) {
        if AudioOutputDevices.setDefault(device.id) {
            currentOutputDeviceID = device.id
        }
    }
}

/// Resumes a continuation exactly once (first caller wins), for timeout races.
private nonisolated final class ResumeOnce<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, Never>?

    init(_ continuation: CheckedContinuation<Value, Never>) {
        self.continuation = continuation
    }

    func resume(_ value: Value) {
        lock.lock()
        let pending = continuation
        continuation = nil
        lock.unlock()
        pending?.resume(returning: value)
    }
}
