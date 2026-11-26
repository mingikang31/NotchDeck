import SwiftUI

/// Expanded notch content: module tabs, then the selected module. When the trial has ended
/// without a license, the activation gate replaces the module body.
struct ExpandedShellView: View {
    let model: NotchViewModel

    @Environment(ThemeEngine.self) private var themeEngine
    @Environment(LicenseManager.self) private var license
    @Environment(SettingsStore.self) private var settings
    @Environment(\.settingsOpener) private var settingsOpener

    var body: some View {
        let tokens = themeEngine.tokens
        let geometry = model.geometry
        let ear = geometry.metrics(for: .expanded).earRadius
        let modules = license.isUnlocked ? settings.enabledModules : []
        let selected = Self.resolvedSelection(model.selectedModule, enabled: modules)

        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                ModuleTabStrip(modules: modules, selected: selected, tokens: tokens) { module in
                    withAnimation(.smooth(duration: 0.25)) { model.selectedModule = module }
                }
                Spacer(minLength: 12)
                ThemeSwitcher()
                IconButton(symbol: "gearshape.fill", help: "NotchDeck Settings", tokens: tokens) {
                    model.onRequestCollapse()
                    settingsOpener.open(.general)
                }
            }

            Group {
                if !license.isUnlocked {
                    ActivationGateView(tokens: tokens) {
                        model.onRequestCollapse()
                        settingsOpener.open(.license)
                    }
                } else if let selected {
                    moduleBody(selected, tokens: tokens)
                        .id(selected)
                        .transition(.opacity)
                } else {
                    NoModulesView(tokens: tokens) {
                        model.onRequestCollapse()
                        settingsOpener.open(.modules)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .foregroundStyle(tokens.primaryText)
        .padding(.top, geometry.topInset + 10)
        .padding(.horizontal, ear + 20)
        .padding(.bottom, 14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    /// The stored selection if it's still enabled, otherwise the first enabled module.
    static func resolvedSelection(_ selection: NotchModule?, enabled: [NotchModule]) -> NotchModule? {
        if let selection, enabled.contains(selection) { return selection }
        return enabled.first
    }

    @ViewBuilder
    private func moduleBody(_ module: NotchModule, tokens: ThemeTokens) -> some View {
        switch module {
        case .media: MediaModuleView(tokens: tokens)
        case .fileTray: FileTrayModuleView(tokens: tokens)
        case .calendar: CalendarModuleView(tokens: tokens)
        default: ComingSoonView(module: module, tokens: tokens)
        }
    }
}

/// Clickable tab bar for the enabled modules, in the user's order (Settings → Modules).
private struct ModuleTabStrip: View {
    let modules: [NotchModule]
    let selected: NotchModule?
    let tokens: ThemeTokens
    let select: (NotchModule) -> Void

    @Namespace private var highlight

    var body: some View {
        HStack(spacing: 3) {
            ForEach(modules) { module in
                let isSelected = module == selected
                Button { select(module) } label: {
                    Image(systemName: module.symbolName)
                        .font(.system(size: 11, weight: .semibold))
                        .frame(width: 26, height: 22)
                        .foregroundStyle(isSelected ? tokens.primaryText : tokens.secondaryText.opacity(module.isAvailable ? 1 : 0.55))
                        .background {
                            if isSelected {
                                RoundedRectangle(cornerRadius: 7, style: .continuous)
                                    .fill(tokens.controlSelectedFill)
                                    .matchedGeometryEffect(id: "tab", in: highlight)
                            } else {
                                RoundedRectangle(cornerRadius: 7, style: .continuous).fill(tokens.controlFill)
                            }
                        }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(module.isAvailable ? module.displayName : "\(module.displayName) — arrives in Phase \(module.phase)")
                .accessibilityLabel(module.displayName)
                .accessibilityAddTraits(isSelected ? .isSelected : [])
            }
        }
    }
}

/// Placeholder body for modules that ship in a later phase.
private struct ComingSoonView: View {
    let module: NotchModule
    let tokens: ThemeTokens

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: module.symbolName)
                .font(.system(size: 22, weight: .semibold))
                .frame(width: 56, height: 56)
                .background(tokens.controlFill, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            VStack(alignment: .leading, spacing: 3) {
                Text(module.displayName).font(.system(size: 14, weight: .semibold))
                Text("Arrives in Phase \(module.phase) of the roadmap.")
                    .font(.system(size: 11))
                    .foregroundStyle(tokens.secondaryText)
            }
            Spacer()
        }
    }
}

private struct NoModulesView: View {
    let tokens: ThemeTokens
    let openSettings: () -> Void

    var body: some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text("No modules enabled").font(.system(size: 14, weight: .semibold))
                Button("Choose Modules…", action: openSettings).controlSize(.small)
            }
            Spacer()
        }
    }
}

private struct IconButton: View {
    let symbol: String
    let help: String
    let tokens: ThemeTokens
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .semibold))
                .frame(width: 26, height: 24)
                .foregroundStyle(tokens.secondaryText)
                .background(tokens.controlFill, in: Circle())
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(help)
    }
}

/// Compact segmented control that flips the theme live, inside the notch.
struct ThemeSwitcher: View {
    @Environment(ThemeEngine.self) private var themeEngine
    @Namespace private var selection

    var body: some View {
        let tokens = themeEngine.tokens
        HStack(spacing: 2) {
            ForEach(NotchTheme.allCases) { theme in
                let isSelected = themeEngine.current == theme
                Button {
                    themeEngine.select(theme)
                } label: {
                    Image(systemName: theme.symbolName)
                        .font(.system(size: 11, weight: .semibold))
                        .frame(width: 28, height: 20)
                        .foregroundStyle(isSelected ? tokens.primaryText : tokens.secondaryText)
                        .background {
                            if isSelected {
                                Capsule()
                                    .fill(tokens.controlSelectedFill)
                                    .matchedGeometryEffect(id: "selection", in: selection)
                            }
                        }
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .help(theme.displayName)
                .accessibilityLabel(theme.displayName)
            }
        }
        .padding(2)
        .background(tokens.controlFill, in: Capsule())
    }
}
