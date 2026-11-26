import SwiftUI

/// NotchDeck is an agent app (`LSUIElement = YES`): no Dock icon, no main window.
/// UI lives in the notch panels, the menu bar status item, and the Settings window.
@main
struct NotchDeckApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        // The 6-tab SettingsView is hosted by `SettingsWindowController`: a Dock-less agent app
        // can't reliably open SwiftUI's `Settings` scene programmatically (from the menu bar
        // item or the notch). The ⌘, command is routed to the same window.
        Settings {
            EmptyView()
        }
        .commands {
            CommandGroup(replacing: .appSettings) {
                Button("Settings…") { appDelegate.container.openSettings() }
                    .keyboardShortcut(",", modifiers: .command)
            }
        }
    }
}
