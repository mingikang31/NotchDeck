import KeyboardShortcuts
import SwiftUI

struct ShortcutsSettingsPane: View {
    var body: some View {
        Form {
            Section {
                ForEach(ShortcutAction.allCases) { action in
                    VStack(alignment: .leading, spacing: 2) {
                        KeyboardShortcuts.Recorder(action.title, name: action.name)
                        if let module = action.pendingModule {
                            Text("Takes full effect when \(module.displayName) ships in Phase \(module.phase).")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            } footer: {
                HStack {
                    Text("Shortcuts work system-wide, even while another app is in front.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Restore Defaults") { ShortcutManager.restoreDefaults() }
                }
            }
        }
        .formStyle(.grouped)
    }
}
