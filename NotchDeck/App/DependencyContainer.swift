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
    let chat: ChatStore
    let modelCatalog: ModelCatalog
    let agentHooks: AgentHookStore
    let systemMonitor: SystemMonitorStore
    let toasts: NotchToastCenter
    let liveActivities: LiveActivitiesStore
    let pomodoro: PomodoroTimer
    let todos: TodoStore
    let clipboard: ClipboardStore
    let mirror: CameraMirrorStore
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
            .environment(services.chat)
            .environment(services.modelCatalog)
            .environment(services.agentHooks)
            .environment(services.systemMonitor)
            .environment(services.toasts)
            .environment(services.liveActivities)
            .environment(services.pomodoro)
            .environment(services.todos)
            .environment(services.clipboard)
            .environment(services.mirror)
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
        let store = secureStore ?? (settings.usesEphemeralSecureStore ? InMemorySecureStore() : SecretsVault(
            items: SystemKeychain(),
            legacyAccounts: [LicenseManager.vaultAccount, "api.anthropic", "api.gemini", "api.openAICompatible"]
        ))
        let license = LicenseManager.live(store: store)
        let nowPlaying = NowPlayingStore()
        let calendar = CalendarStore(settings: settings)
        let apiKeys = APIKeyStore(store: store)
        let catalog = ModelCatalog(settings: settings, apiKeys: apiKeys)
        let agentHooks = AgentHookStore(settings: settings)
        let toasts = NotchToastCenter()
        let pomodoro = PomodoroTimer(settings: settings, toasts: toasts, defaults: defaults)
        services = AppServices(
            settings: settings,
            themeEngine: ThemeEngine(settings: settings),
            licenseManager: license,
            updateManager: UpdateManager(),
            launchAtLogin: LaunchAtLoginService(),
            apiKeys: apiKeys,
            settingsOpener: SettingsOpener(),
            nowPlaying: nowPlaying,
            fileTray: FileTrayStore(),
            calendar: calendar,
            liveActivity: LiveActivityCoordinator(
                media: nowPlaying, calendar: calendar, settings: settings, license: license,
                agentHooks: agentHooks, toasts: toasts, pomodoro: pomodoro
            ),
            chat: ChatStore(settings: settings, apiKeys: apiKeys, catalog: catalog),
            modelCatalog: catalog,
            agentHooks: agentHooks,
            systemMonitor: SystemMonitorStore(settings: settings),
            toasts: toasts,
            liveActivities: LiveActivitiesStore(toasts: toasts),
            pomodoro: pomodoro,
            todos: TodoStore(),
            clipboard: ClipboardStore(settings: settings),
            mirror: CameraMirrorStore()
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
        services.chat.onShowChat = { [weak self] in self?.windowController.focusChat() }
        services.chat.onHideNotch = { [weak self] in self?.windowController.collapseAll() }
        services.agentHooks.onApprovalNeeded = { [weak self] in self?.windowController.showAgentApproval() }
        services.agentHooks.onQueueEmptied = { [weak self] in self?.windowController.collapse(ifShowing: .agentHooks) }
        services.licenseManager.start()
        services.apiKeys.refresh()
        // Fresh model lists for every configured provider (cached lists show meanwhile).
        Task { await services.modelCatalog.refreshAll() }
        windowController.start()
        services.updateManager.start()
        services.liveActivity.start()
        services.pomodoro.resume()

        // Modules run only while enabled in Settings → Modules and unlocked by the license.
        observeContinuously({ [weak self] in
            guard let self else { return [NotchModule]() }
            return self.services.licenseManager.isUnlocked ? self.settings.enabledModules : []
        }) { [weak self] active in
            self?.applyModuleActivation(active)
        }
        applyModuleActivation(services.licenseManager.isUnlocked ? settings.enabledModules : [])

        // Live Activities: each watcher runs only while the module and its own toggle are on.
        observeContinuously({ [weak self] in
            self?.liveActivation ?? .off
        }) { [weak self] activation in
            self?.services.liveActivities.apply(activation)
        }
        services.liveActivities.apply(liveActivation)

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
        services.agentHooks.setActive(active.contains(.agentHooks))
        services.calendar.setActive(active.contains(.calendar))
        services.clipboard.setActive(active.contains(.clipboard))
        if !active.contains(.pomodoro), services.pomodoro.state.isRunning {
            services.pomodoro.pause()
        }
    }

    private var liveActivation: LiveActivitiesStore.Activation {
        guard services.licenseManager.isUnlocked, settings.enabledModules.contains(.liveActivities) else { return .off }
        return .init(
            battery: settings.liveBatteryEnabled,
            bluetooth: settings.liveBluetoothEnabled,
            downloads: settings.liveDownloadsEnabled
        )
    }

    private func isUsable(_ module: NotchModule) -> Bool {
        services.licenseManager.isUnlocked && settings.enabledModules.contains(module)
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
            windowController.toggleChat()
        case .approveAgentRequest:
            services.agentHooks.approve()
        case .togglePomodoro:
            guard isUsable(.pomodoro) else { return }
            services.pomodoro.toggle()
        case .toggleCameraMirror:
            guard isUsable(.mirror) else { return }
            windowController.toggleModule(.mirror)
        }
    }

    /// True when the app is hosting a unit-test bundle; UI startup is skipped then.
    static var isRunningTests: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
            || NSClassFromString("XCTestCase") != nil
    }
}
