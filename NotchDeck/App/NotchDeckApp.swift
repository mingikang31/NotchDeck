import SwiftUI

/// NotchDeck is an agent app (`LSUIElement = YES`): no Dock icon, no main window.
/// All UI lives in the notch panels and the menu bar status item.
@main
struct NotchDeckApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        // Placeholder; the 6-tab Settings window is built in Phase 2.
        Settings {
            Text("Settings arrive in Phase 2. Use the menu bar icon for now.")
                .padding(40)
        }
    }
}
