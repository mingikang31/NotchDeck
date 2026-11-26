import Foundation
import Observation

/// User preferences backed by `UserDefaults`.
///
/// Phase 1 holds only what the window shell needs; Phase 2 grows this into the full
/// settings model behind the 6-tab Settings window. Any key can be overridden at launch
/// via the argument domain, e.g. `-notchdeck.theme frostedGlass`.
@Observable
final class SettingsStore {
    private enum Key {
        static let theme = "notchdeck.theme"
        static let displayPolicy = "notchdeck.displayPolicy"
        static let sizePreset = "notchdeck.sizePreset"
        static let hoverDelay = "notchdeck.hoverDelayMilliseconds"
        static let geometryOutline = "notchdeck.debug.showsGeometryOutline"
        static let startExpanded = "notchdeck.debug.startExpanded"
    }

    @ObservationIgnored private let defaults: UserDefaults

    var theme: NotchTheme {
        didSet { defaults.set(theme.rawValue, forKey: Key.theme) }
    }

    var displayPolicy: DisplayPolicy {
        didSet { defaults.set(displayPolicy.rawValue, forKey: Key.displayPolicy) }
    }

    var sizePreset: NotchSizePreset {
        didSet { defaults.set(sizePreset.rawValue, forKey: Key.sizePreset) }
    }

    /// Hover dwell before expanding (spec: configurable 0–500 ms, default 150 ms).
    var hoverDelayMilliseconds: Int {
        didSet { defaults.set(hoverDelayMilliseconds, forKey: Key.hoverDelay) }
    }

    /// Debug overlay that outlines the computed cutout to verify hardware alignment.
    var showsGeometryOutline: Bool {
        didSet { defaults.set(showsGeometryOutline, forKey: Key.geometryOutline) }
    }

    /// Debug: open (pinned) right after launch. Read-only; set via launch argument.
    let startExpanded: Bool

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        theme = defaults.string(forKey: Key.theme).flatMap(NotchTheme.init(rawValue:)) ?? .classicBlack
        displayPolicy = defaults.string(forKey: Key.displayPolicy).flatMap(DisplayPolicy.init(rawValue:)) ?? .notchDisplay
        sizePreset = defaults.string(forKey: Key.sizePreset).flatMap(NotchSizePreset.init(rawValue:)) ?? .medium
        let storedDelay = defaults.object(forKey: Key.hoverDelay) as? Int ?? 150
        hoverDelayMilliseconds = min(max(storedDelay, 0), 500)
        showsGeometryOutline = defaults.bool(forKey: Key.geometryOutline)
        startExpanded = defaults.bool(forKey: Key.startExpanded)
    }
}
