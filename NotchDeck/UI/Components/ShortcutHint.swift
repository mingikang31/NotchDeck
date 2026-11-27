import SwiftUI

/// A hint that names the user's *current* shortcut for an action and updates the moment it's
/// changed in Settings → Shortcuts (e.g. "⌃⇧C opens this chat from anywhere").
struct ShortcutHint: View {
    let action: ShortcutAction
    /// Builds the hint from the key combination, e.g. `{ "\($0) opens this chat from anywhere" }`.
    let text: (String) -> String
    /// Shown when no shortcut is recorded.
    let unsetText: String
    var symbol = "command"

    @State private var shortcut: String?

    var body: some View {
        Label(shortcut.map(text) ?? unsetText, systemImage: symbol)
            .onAppear { shortcut = action.currentShortcutDescription }
            .onReceive(NotificationCenter.default.publisher(for: ShortcutAction.didChangeNotification)) { _ in
                shortcut = action.currentShortcutDescription
            }
    }
}
