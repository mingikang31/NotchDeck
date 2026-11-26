import AppKit
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
}

extension View {
    func appServices(_ services: AppServices) -> some View {
        environment(services.settings)
            .environment(services.themeEngine)
            .environment(services.licenseManager)
            .environment(services.updateManager)
            .environment(services.launchAtLogin)
            .environment(services.apiKeys)
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
        services = AppServices(
            settings: settings,
            themeEngine: ThemeEngine(settings: settings),
            licenseManager: LicenseManager.live(store: store),
            updateManager: UpdateManager(),
            launchAtLogin: LaunchAtLoginService(),
            apiKeys: APIKeyStore(store: store),
            settingsOpener: SettingsOpener()
        )
        windowController = NotchWindowController(services: services)
    }

    func start() {
        services.settingsOpener.handler = { [weak self] pane in self?.openSettings(pane) }
        services.licenseManager.start()
        services.apiKeys.refresh()
        windowController.start()
        services.updateManager.start()

        let shortcuts = ShortcutManager { [weak self] action in self?.perform(action) }
        shortcuts.register()
        shortcutManager = shortcuts
    }

    func stop() {
        windowController.stop()
        services.licenseManager.stop()
    }

    func openSettings(_ pane: SettingsPane = .general) {
        windowController.collapseAll()
        settingsWindowController.show(pane)
    }

    private func perform(_ action: ShortcutAction) {
        switch action {
        case .toggleNotch:
            windowController.toggleExpanded()
        case .openAIChat, .openFileTray:
            // Opens the notch now; the modules focus their own UI once they ship (Phases 3–4).
            windowController.expandPinned()
        case .togglePlayPause, .togglePomodoro, .toggleCameraMirror, .approveAgentRequest:
            break // Wired when the corresponding module ships.
        }
    }

    /// True when the app is hosting a unit-test bundle; UI startup is skipped then.
    static var isRunningTests: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
            || NSClassFromString("XCTestCase") != nil
    }
}
