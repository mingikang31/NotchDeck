import Combine
import Foundation
import Observation
import OSLog
import Sparkle

/// Sparkle 2 updater. Stays dormant until both `SUFeedURL` and `SUPublicEDKey` are set
/// (Config/NotchDeck.xcconfig), so unconfigured builds never show a Sparkle error at launch.
@Observable
final class UpdateManager {
    let isConfigured: Bool
    private(set) var canCheckForUpdates = false

    var automaticallyChecksForUpdates = false {
        didSet {
            guard isStarted, controller.updater.automaticallyChecksForUpdates != automaticallyChecksForUpdates else { return }
            controller.updater.automaticallyChecksForUpdates = automaticallyChecksForUpdates
        }
    }

    @ObservationIgnored private let controller: SPUStandardUpdaterController
    @ObservationIgnored private var canCheckObservation: AnyCancellable?
    @ObservationIgnored private var isStarted = false
    @ObservationIgnored private let logger = Logger(subsystem: "com.notchdeck.NotchDeck", category: "Updates")

    init(bundle: Bundle = .main) {
        func value(_ key: String) -> String {
            (bundle.object(forInfoDictionaryKey: key) as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        }
        let feed = URL(string: value("SUFeedURL"))
        isConfigured = feed?.scheme == "https" && !value("SUPublicEDKey").isEmpty
        controller = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: nil, userDriverDelegate: nil)
    }

    func start() {
        guard isConfigured, !isStarted else {
            if !isConfigured { logger.notice("Sparkle disabled: SUFeedURL / SUPublicEDKey not configured.") }
            return
        }
        controller.startUpdater()
        isStarted = true
        automaticallyChecksForUpdates = controller.updater.automaticallyChecksForUpdates
        canCheckObservation = controller.updater.publisher(for: \.canCheckForUpdates)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] value in
                MainActor.assumeIsolated { self?.canCheckForUpdates = value }
            }
    }

    func checkForUpdates() {
        guard isStarted else { return }
        controller.checkForUpdates(nil)
    }

    var versionDescription: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "\(version) (\(build))"
    }
}
