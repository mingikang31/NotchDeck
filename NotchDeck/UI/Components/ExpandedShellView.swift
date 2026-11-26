import SwiftUI

/// Phase 1 expanded content: a module tab strip placeholder, a live theme switcher,
/// an ambient-glow preview, and a geometry readout for verifying notch alignment.
/// Real module content replaces the body in Phases 3–6.
struct ExpandedShellView: View {
    let model: NotchViewModel

    @Environment(ThemeEngine.self) private var themeEngine

    var body: some View {
        let tokens = themeEngine.tokens
        let geometry = model.geometry
        let ear = geometry.metrics(for: .expanded).earRadius

        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                ModuleTabStrip(tokens: tokens)
                Spacer(minLength: 12)
                ThemeSwitcher()
            }

            HStack(alignment: .center, spacing: 16) {
                AmbientGlowPreview(intensity: tokens.glowOpacity)

                VStack(alignment: .leading, spacing: 3) {
                    Text("NotchDeck")
                        .font(.system(size: 15, weight: .semibold))
                    Text("Phase 1 · window shell & themes")
                        .font(.system(size: 11))
                        .foregroundStyle(tokens.secondaryText)
                }

                Spacer(minLength: 12)

                GeometryReadout(model: model, tokens: tokens)
            }
        }
        .foregroundStyle(tokens.primaryText)
        .padding(.top, geometry.topInset + 10)
        .padding(.horizontal, ear + 20)
        .padding(.bottom, 16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}

/// Placeholder tab bar for the modules that arrive in later phases.
private struct ModuleTabStrip: View {
    let tokens: ThemeTokens

    private let modules: [(symbol: String, name: String)] = [
        ("play.circle.fill", "Media"),
        ("tray.fill", "File Tray"),
        ("sparkles", "AI Chat"),
        ("terminal.fill", "Agents"),
        ("calendar", "Calendar"),
        ("bolt.fill", "Live Activities"),
    ]

    var body: some View {
        HStack(spacing: 4) {
            ForEach(modules, id: \.name) { module in
                Image(systemName: module.symbol)
                    .font(.system(size: 11, weight: .semibold))
                    .frame(width: 26, height: 22)
                    .foregroundStyle(tokens.secondaryText)
                    .background(tokens.controlFill, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                    .help("\(module.name) — coming in a later phase")
            }
        }
    }
}

/// Segmented control that flips the theme at runtime, live, inside the notch.
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
                    Label(theme.shortName, systemImage: theme.symbolName)
                        .font(.system(size: 11, weight: .semibold))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
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
                .accessibilityLabel(theme.displayName)
            }
        }
        .padding(3)
        .background(tokens.controlFill, in: Capsule())
    }
}

/// Artwork placeholder with the ambient glow the Now Playing module will use.
/// The pulse stands in for audio reactivity until Phase 3 wires real levels.
private struct AmbientGlowPreview: View {
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
            .fill(
                LinearGradient(
                    colors: [Color(red: 1.0, green: 0.36, blue: 0.52), Color(red: 0.55, green: 0.32, blue: 1.0)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
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
