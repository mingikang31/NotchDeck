import SwiftUI

struct AppearanceSettingsPane: View {
    @Environment(SettingsStore.self) private var settings
    @Environment(ThemeEngine.self) private var themeEngine

    var body: some View {
        @Bindable var settings = settings

        Form {
            Section("Theme") {
                HStack(spacing: 14) {
                    ForEach(NotchTheme.allCases) { theme in
                        ThemeCard(theme: theme, isSelected: settings.theme == theme) {
                            themeEngine.select(theme)
                        }
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 4)
            }

            Section("Expanded Notch") {
                Picker("Size", selection: $settings.sizePreset) {
                    ForEach(NotchSizePreset.allCases) { Text($0.displayName).tag($0) }
                }
                .pickerStyle(.segmented)
                Toggle("Hide the collapsed pill when idle", isOn: $settings.hidesIdlePill)
                Text("Applies to displays without a notch. The pill reappears when you point at it.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Section("Audio Visualizer") {
                Picker("Style", selection: $settings.visualizerStyle) {
                    ForEach(VisualizerStyle.allCases) { Text($0.displayName).tag($0) }
                }
                .pickerStyle(.segmented)
                LabeledContent("Accent color") {
                    HStack(spacing: 8) {
                        ForEach(AccentColorChoice.allCases) { choice in
                            AccentSwatch(choice: choice, isSelected: settings.accentColor == choice) {
                                settings.accentColor = choice
                            }
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
    }
}

/// Selectable preview of a theme: a miniature notch silhouette on a wallpaper-like backdrop.
private struct ThemeCard: View {
    let theme: NotchTheme
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 8) {
                ZStack(alignment: .top) {
                    LinearGradient(
                        colors: [Color(red: 0.36, green: 0.42, blue: 0.78), Color(red: 0.86, green: 0.48, blue: 0.62)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                    preview
                        .frame(width: 150, height: 44)
                }
                .frame(width: 200, height: 84)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(isSelected ? Color.accentColor : Color.secondary.opacity(0.25), lineWidth: isSelected ? 2.5 : 1)
                }

                Text(theme.displayName)
                    .font(.callout.weight(isSelected ? .semibold : .regular))
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    @ViewBuilder
    private var preview: some View {
        let shape = NotchMaskShape(earRadius: 6, bottomRadius: 14)
        switch theme {
        case .classicBlack:
            shape.fill(Color.black)
        case .frostedGlass:
            shape.fill(.ultraThinMaterial)
                .environment(\.colorScheme, .dark)
                .overlay {
                    shape.stroke(
                        LinearGradient(colors: [.white.opacity(0.35), .white.opacity(0.08)], startPoint: .top, endPoint: .bottom),
                        lineWidth: 2
                    )
                    .clipShape(shape)
                }
        }
    }
}

private struct AccentSwatch: View {
    let choice: AccentColorChoice
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Group {
                if choice == .artwork {
                    // Multicolor "from the album art" swatch.
                    Circle()
                        .fill(AngularGradient(colors: [.red, .orange, .yellow, .green, .blue, .purple, .red], center: .center))
                        .overlay(Image(systemName: "photo").font(.system(size: 8, weight: .bold)).foregroundStyle(.white))
                } else {
                    Circle()
                        .fill(LinearGradient(colors: choice.gradient, startPoint: .topLeading, endPoint: .bottomTrailing))
                }
            }
                .frame(width: 18, height: 18)
                .overlay {
                    Circle().strokeBorder(Color.primary.opacity(isSelected ? 0.9 : 0), lineWidth: 2).padding(-3)
                }
                .padding(3)
        }
        .buttonStyle(.plain)
        .help(choice.displayName)
        .accessibilityLabel(choice.displayName)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}
