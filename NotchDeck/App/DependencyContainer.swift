import AppKit
import EventKit
import SwiftUI

/// Late-bound "open Settings at pane X" action, usable from SwiftUI (environment) and AppKit.
final class SettingsOpener {
    /// Inert default for the environment (views outside the app's hierarchy, previews).
    static let inert = SettingsOpener()

    var handler: ((SettingsPane) -> Void)?

    func open(_ pane: SettingsPane = .general) {
        handler?(pane)
    }
}

extension EnvironmentValues {
    @Entry var settingsOpener = SettingsOpener.inert
}

/// The shared stores every view may need.
struct AppServices {
    let settings: SettingsStore
    let themeEngine: ThemeEngine
    let licenseManager: LicenseManager
    let updateManager: UpdateManager
    let launchAtLogin: LaunchAtLoginService
    let apiKeys: APIKeyStore
    let settingsOpener: SettingsOpener
    let nowPlaying: NowPlayingStore
    let fileTray: FileTrayStore
    let calendar: CalendarStore
    let liveActivity: LiveActivityCoordinator
}

extension View {
    func appServices(_ services: AppServices) -> some View {
        environment(services.settings)
            .environment(services.themeEngine)
            .environment(services.licenseManager)
            .environment(services.updateManager)
            .environment(services.launchAtLogin)
            .environment(services.apiKeys)
            .environment(services.nowPlaying)
            .environment(services.fileTray)
            .environment(services.calendar)
            .environment(services.liveActivity)
            .environment(\.settingsOpener, services.settingsOpener)
    }
}

/// Composition root. `init` has no side effects (no Keychain, windows or hotkeys) so the
/// unit-test host can construct it safely; `start()` brings the app up.
final class DependencyContainer {
    let services: AppServices
    let windowController: NotchWindowController
    private var shortcutManager: ShortcutManager?
    private lazy var settingsWindowController = SettingsWindowController(services: services)

    var settings: SettingsStore { services.settings }
    var licenseManager: LicenseManager { services.licenseManager }
    var updateManager: UpdateManager { services.updateManager }

    init(defaults: UserDefaults = .standard, secureStore: SecureStore? = nil) {
        let settings = SettingsStore(defaults: defaults)
        let store = secureStore ?? (settings.usesEphemeralSecureStore ? InMemorySecureStore() : KeychainHelper())
        let license = LicenseManager.live(store: store)
        let nowPlaying = NowPlayingStore()
        let calendar = CalendarStore(settings: settings)
        services = AppServices(
            settings: settings,
            themeEngine: ThemeEngine(settings: settings),
            licenseManager: license,
            updateManager: UpdateManager(),
            launchAtLogin: LaunchAtLoginService(),
            apiKeys: APIKeyStore(store: store),
            settingsOpener: SettingsOpener(),
            nowPlaying: nowPlaying,
            fileTray: FileTrayStore(),
            calendar: calendar,
            liveActivity: LiveActivityCoordinator(media: nowPlaying, calendar: calendar, settings: settings, license: license)
        )
        windowController = NotchWindowController(services: services)
    }

    func start() {
        // Per-session permissions: forget last run's approvals before anything can use them.
        if settings.permissionsPerSession {
            // Remember a calendar approval from the last run before forgetting it, so it's re-asked below.
            if EKEventStore.authorizationStatus(for: .event) == .fullAccess {
                settings.calendarWasConnected = true
            }
            SessionPermissions.resetAll()
        }
        services.settingsOpener.handler = { [weak self] pane in self?.openSettings(pane) }
        services.licenseManager.start()
        services.apiKeys.refresh()
        windowController.start()
        services.updateManager.start()
        services.liveActivity.start()

        // Modules run only while enabled in Settings → Modules and unlocked by the license.
        observeContinuously({ [weak self] in
            guard let self else { return [NotchModule]() }
            return self.services.licenseManager.isUnlocked ? self.settings.enabledModules : []
        }) { [weak self] active in
            self?.applyModuleActivation(active)
        }
        applyModuleActivation(services.licenseManager.isUnlocked ? settings.enabledModules : [])

        // Calendar was reset above; if the user had connected it before, ask again right away
        // rather than leaving the module disconnected until they find the button.
        if settings.permissionsPerSession, settings.calendarWasConnected,
           settings.enabledModules.contains(.calendar), services.licenseManager.isUnlocked {
            Task { await services.calendar.requestAccess() }
        }

        let shortcuts = ShortcutManager { [weak self] action in self?.perform(action) }
        shortcuts.register()
        shortcutManager = shortcuts
    }

    func stop() {
        windowController.stop()
        services.licenseManager.stop()
        if settings.permissionsPerSession {
            SessionPermissions.resetAll()
        }
    }

    func openSettings(_ pane: SettingsPane = .general) {
        windowController.collapseAll()
        settingsWindowController.show(pane)
    }

    private func applyModuleActivation(_ active: [NotchModule]) {
        services.nowPlaying.setActive(active.contains(.media))
        services.calendar.setActive(active.contains(.calendar))
    }

    private func perform(_ action: ShortcutAction) {
        switch action {
        case .toggleNotch:
            windowController.toggleExpanded()
        case .openFileTray:
            windowController.expandPinned(showing: .fileTray)
        case .togglePlayPause:
            services.nowPlaying.perform(.playPause)
        case .openAIChat:
            // Opens the notch now; the chat focuses its input once it ships (Phase 4).
            windowController.expandPinned(showing: .aiChat)
        case .togglePomodoro, .toggleCameraMirror, .approveAgentRequest:
            break // Wired when the corresponding module ships.
        }
    }

    /// True when the app is hosting a unit-test bundle; UI startup is skipped then.
    static var isRunningTests: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
            || NSClassFromString("XCTestCase") != nil
    }
}
