import SwiftUI

/// Expanded notch content. Until the modules ship (Phases 3–6) the body is a shell with an
/// ambient-glow preview and a geometry readout; when the trial has ended and no license is
/// active, the body is replaced by the activation gate.
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

        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                ModuleTabStrip(modules: license.isUnlocked ? settings.enabledModules : [], tokens: tokens)
                Spacer(minLength: 12)
                ThemeSwitcher()
                IconButton(symbol: "gearshape.fill", help: "NotchDeck Settings", tokens: tokens) {
                    model.onRequestCollapse()
                    settingsOpener.open(.general)
                }
            }

            if license.isUnlocked {
                HStack(alignment: .center, spacing: 16) {
                    AmbientGlowPreview(colors: settings.accentColor.gradient, intensity: tokens.glowOpacity)

                    VStack(alignment: .leading, spacing: 3) {
                        Text("NotchDeck")
                            .font(.system(size: 15, weight: .semibold))
                        Text(license.trialBadgeText ?? "Modules arrive in upcoming phases")
                            .font(.system(size: 11))
                            .foregroundStyle(tokens.secondaryText)
                    }

                    Spacer(minLength: 12)

                    GeometryReadout(model: model, tokens: tokens)
                }
            } else {
                ActivationGateView(tokens: tokens) {
                    model.onRequestCollapse()
                    settingsOpener.open(.license)
                }
            }
        }
        .foregroundStyle(tokens.primaryText)
        .padding(.top, geometry.topInset + 10)
        .padding(.horizontal, ear + 20)
        .padding(.bottom, 16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}

/// Tab bar for the enabled modules, in the user's order (Settings → Modules).
private struct ModuleTabStrip: View {
    let modules: [NotchModule]
    let tokens: ThemeTokens

    var body: some View {
        HStack(spacing: 3) {
            ForEach(modules) { module in
                Image(systemName: module.symbolName)
                    .font(.system(size: 11, weight: .semibold))
                    .frame(width: 24, height: 22)
                    .foregroundStyle(tokens.secondaryText)
                    .background(tokens.controlFill, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                    .help("\(module.displayName) — arrives in Phase \(module.phase)")
            }
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

/// Artwork placeholder with the ambient glow the Now Playing module will use.
/// The pulse stands in for audio reactivity until Phase 3 wires real levels.
private struct AmbientGlowPreview: View {
    let colors: [Color]
    let intensity: Double

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            let pulse = 0.82 + 0.18 * sin(t * 2.2)
            artwork
                .background {
                    artwork
                        .blur(radius: 16)
                        .scaleEffect(1.1 + 0.08 * pulse)
                        .opacity(intensity * pulse)
                }
        }
    }

    private var artwork: some View {
        RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing))
            .frame(width: 56, height: 56)
            .overlay {
                Image(systemName: "waveform")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.9))
            }
    }
}

/// Live readout of the computed geometry for the panel's display.
private struct GeometryReadout: View {
    let model: NotchViewModel
    let tokens: ThemeTokens

    var body: some View {
        let g = model.geometry
        Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 3) {
            row("Display", model.displayName)
            row("Cutout", g.kind == .hardwareNotch ? "Hardware notch" : "Fallback pill")
            row("Size", "\(g.cutout.width.pt) × \(g.cutout.height.pt) pt")
            row("Span", "x \(g.cutout.minX.pt) – \(g.cutout.maxX.pt)")
            row("Refresh", "\(model.refreshRate) Hz")
        }
        .font(.system(size: 10.5, design: .monospaced))
    }

    private func row(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label).foregroundStyle(tokens.secondaryText)
            Text(value).lineLimit(1)
        }
    }
}
