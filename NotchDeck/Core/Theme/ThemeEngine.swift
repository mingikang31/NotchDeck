import Observation
import SwiftUI

enum NotchTheme: String, CaseIterable, Identifiable, Sendable {
    /// Pure #000000 that blends into the physical camera housing.
    case classicBlack
    /// Behind-window HUD material with a specular edge stroke and ambient glow.
    case frostedGlass

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .classicBlack: "Classic Black"
        case .frostedGlass: "Frosted Glass"
        }
    }

    var shortName: String {
        switch self {
        case .classicBlack: "Black"
        case .frostedGlass: "Glass"
        }
    }

    var symbolName: String {
        switch self {
        case .classicBlack: "circle.fill"
        case .frostedGlass: "circle.lefthalf.filled"
        }
    }
}

/// Design tokens for one theme.
struct ThemeTokens {
    var material: NSVisualEffectView.Material?
    /// Darkening layer over the material for text legibility on bright wallpapers.
    var materialTint: Color
    /// 1pt inner specular border (vertical gradient), if any.
    var borderGradient: LinearGradient?
    var shadowOpacity: Double
    var shadowRadius: CGFloat
    var shadowYOffset: CGFloat
    var glowOpacity: Double
    var primaryText: Color
    var secondaryText: Color
    var controlFill: Color
    var controlSelectedFill: Color

    static let classicBlack = ThemeTokens(
        material: nil,
        materialTint: .clear,
        borderGradient: nil,
        shadowOpacity: 0.55,
        shadowRadius: 18,
        shadowYOffset: 8,
        glowOpacity: 0.35,
        primaryText: .white,
        secondaryText: .white.opacity(0.55),
        controlFill: .white.opacity(0.07),
        controlSelectedFill: .white.opacity(0.16)
    )

    static let frostedGlass = ThemeTokens(
        material: .hudWindow,
        materialTint: .black.opacity(0.12),
        borderGradient: LinearGradient(
            colors: [.white.opacity(0.28), .white.opacity(0.06)],
            startPoint: .top,
            endPoint: .bottom
        ),
        shadowOpacity: 0.30,
        shadowRadius: 22,
        shadowYOffset: 10,
        glowOpacity: 0.6,
        primaryText: .white,
        secondaryText: .white.opacity(0.62),
        controlFill: .white.opacity(0.08),
        controlSelectedFill: .white.opacity(0.22)
    )
}

/// Resolves the active theme and its tokens. The selection is persisted by `SettingsStore`;
/// views observe this through the environment and re-render on change.
@Observable
final class ThemeEngine {
    private let settings: SettingsStore

    init(settings: SettingsStore) {
        self.settings = settings
    }

    var current: NotchTheme {
        get { settings.theme }
        set { settings.theme = newValue }
    }

    var tokens: ThemeTokens {
        switch current {
        case .classicBlack: .classicBlack
        case .frostedGlass: .frostedGlass
        }
    }

    func select(_ theme: NotchTheme) {
        withAnimation(NotchMotion.themeSwitch) {
            current = theme
        }
    }
}
