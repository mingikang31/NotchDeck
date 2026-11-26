import Foundation

/// Composition root: shared services and observable stores.
final class DependencyContainer {
    let settings: SettingsStore
    let themeEngine: ThemeEngine
    let windowController: NotchWindowController

    init(defaults: UserDefaults = .standard) {
        settings = SettingsStore(defaults: defaults)
        themeEngine = ThemeEngine(settings: settings)
        windowController = NotchWindowController(settings: settings, themeEngine: themeEngine)
    }

    /// True when the app is hosting a unit-test bundle; UI startup is skipped then.
    static var isRunningTests: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
            || NSClassFromString("XCTestCase") != nil
    }
}
