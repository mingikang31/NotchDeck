import SwiftUI

struct GeneralSettingsPane: View {
    @Environment(SettingsStore.self) private var settings
    @Environment(LaunchAtLoginService.self) private var launchAtLogin
    @Environment(LicenseManager.self) private var license
    @Environment(\.settingsOpener) private var settingsOpener

    var body: some View {
        @Bindable var settings = settings

        Form {
            if let badge = license.trialBadgeText {
                Section {
                    HStack {
                        TrialBadge(text: badge, isExpired: !license.isUnlocked)
                        Spacer()
                        Button(license.isUnlocked ? "Buy or Activate…" : "Activate…") {
                            settingsOpener.open(.license)
                        }
                    }
                }
            }

            Section("Startup") {
                Toggle("Launch at login", isOn: Binding(
                    get: { launchAtLogin.isEnabled || launchAtLogin.requiresApproval },
                    set: { launchAtLogin.setEnabled($0) }
                ))
                if launchAtLogin.requiresApproval {
                    HStack {
                        Text("Approve NotchDeck in Login Items to finish enabling this.")
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Open Login Items…") { launchAtLogin.openLoginItemsSettings() }
                    }
                    .font(.callout)
                }
                if let error = launchAtLogin.lastError {
                    Text(error).font(.callout).foregroundStyle(.red)
                }

                Toggle("Show menu bar icon", isOn: $settings.showsMenuBarIcon)
                if !settings.showsMenuBarIcon {
                    Text("To get back here, open NotchDeck again from Finder or Spotlight, or use the gear in the expanded notch.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Displays") {
                Picker("Show the notch on", selection: $settings.displayPolicy) {
                    ForEach(DisplayPolicy.allCases) { Text($0.displayName).tag($0) }
                }
            }

            Section("Behavior") {
                LabeledContent("Hover open delay") {
                    HStack {
                        Slider(
                            value: Binding(
                                get: { Double(settings.hoverDelayMilliseconds) },
                                set: { settings.hoverDelayMilliseconds = Int($0) }
                            ),
                            in: Double(SettingsStore.hoverDelayRange.lowerBound)...Double(SettingsStore.hoverDelayRange.upperBound),
                            step: 10
                        )
                        Text("\(settings.hoverDelayMilliseconds) ms")
                            .monospacedDigit()
                            .frame(width: 56, alignment: .trailing)
                    }
                }
                Picker("Collapse automatically", selection: $settings.autoCollapse) {
                    ForEach(AutoCollapseBehavior.allCases) { Text($0.displayName).tag($0) }
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { launchAtLogin.refresh() }
    }
}

struct TrialBadge: View {
    let text: String
    let isExpired: Bool

    var body: some View {
        Label(text, systemImage: isExpired ? "exclamationmark.circle.fill" : "clock")
            .font(.callout.weight(.medium))
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .foregroundStyle(isExpired ? Color.orange : Color.secondary)
            .background((isExpired ? Color.orange : Color.secondary).opacity(0.12), in: Capsule())
    }
}
