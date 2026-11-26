import Foundation
import Observation

/// User preferences backed by `UserDefaults`, observed directly by SwiftUI settings panes.
///
/// Any key can be overridden at launch through the argument domain,
/// e.g. `-notchdeck.theme frostedGlass`. Secrets never live here (see `SecureStore`).
@Observable
final class SettingsStore {
    enum Key {
        static let showsMenuBarIcon = "notchdeck.showsMenuBarIcon"
        static let displayPolicy = "notchdeck.displayPolicy"
        static let hoverDelay = "notchdeck.hoverDelayMilliseconds"
        static let autoCollapse = "notchdeck.autoCollapse"
        static let theme = "notchdeck.theme"
        static let sizePreset = "notchdeck.sizePreset"
        static let visualizerStyle = "notchdeck.visualizerStyle"
        static let accentColor = "notchdeck.accentColor"
        static let hidesIdlePill = "notchdeck.hidesIdlePill"
        static let modules = "notchdeck.modules"
        static let chatModel = "notchdeck.chatModel"
        static let chatSystemPrompt = "notchdeck.chatSystemPrompt"
        static let agentServerPort = "notchdeck.agentServerPort"
        static let geometryOutline = "notchdeck.debug.showsGeometryOutline"
        static let startExpanded = "notchdeck.debug.startExpanded"
        static let ephemeralSecureStore = "notchdeck.debug.ephemeralSecureStore"
    }

    static let hoverDelayRange = 0...500
    static let agentPortRange = 1024...65535
    static let defaultAgentPort = 49152
    static let defaultSystemPrompt = "You are a concise assistant living in the Mac's notch. Prefer short, direct answers."

    @ObservationIgnored private let defaults: UserDefaults

    // MARK: General

    var showsMenuBarIcon: Bool { didSet { defaults.set(showsMenuBarIcon, forKey: Key.showsMenuBarIcon) } }
    var displayPolicy: DisplayPolicy { didSet { defaults.set(displayPolicy.rawValue, forKey: Key.displayPolicy) } }
    /// Hover dwell before expanding (0–500 ms, default 150 ms).
    var hoverDelayMilliseconds: Int {
        didSet {
            let clamped = Self.clamp(hoverDelayMilliseconds, to: Self.hoverDelayRange)
            if clamped != hoverDelayMilliseconds { hoverDelayMilliseconds = clamped }
            defaults.set(clamped, forKey: Key.hoverDelay)
        }
    }
    var autoCollapse: AutoCollapseBehavior { didSet { defaults.set(autoCollapse.rawValue, forKey: Key.autoCollapse) } }

    // MARK: Appearance

    var theme: NotchTheme { didSet { defaults.set(theme.rawValue, forKey: Key.theme) } }
    var sizePreset: NotchSizePreset { didSet { defaults.set(sizePreset.rawValue, forKey: Key.sizePreset) } }
    var visualizerStyle: VisualizerStyle { didSet { defaults.set(visualizerStyle.rawValue, forKey: Key.visualizerStyle) } }
    var accentColor: AccentColorChoice { didSet { defaults.set(accentColor.rawValue, forKey: Key.accentColor) } }
    /// Hide the collapsed pill on non-notch displays until hovered.
    var hidesIdlePill: Bool { didSet { defaults.set(hidesIdlePill, forKey: Key.hidesIdlePill) } }

    // MARK: Modules

    /// Tab order + enablement for every module.
    var modules: [ModuleConfiguration] {
        didSet {
            if let data = try? JSONEncoder().encode(modules) { defaults.set(data, forKey: Key.modules) }
        }
    }

    var enabledModules: [NotchModule] { modules.filter(\.isEnabled).map(\.module) }

    // MARK: AI & Agents

    var chatModel: ChatModelChoice { didSet { defaults.set(chatModel.rawValue, forKey: Key.chatModel) } }
    var chatSystemPrompt: String { didSet { defaults.set(chatSystemPrompt, forKey: Key.chatSystemPrompt) } }
    var agentServerPort: Int {
        didSet {
            let clamped = Self.clamp(agentServerPort, to: Self.agentPortRange)
            if clamped != agentServerPort { agentServerPort = clamped }
            defaults.set(clamped, forKey: Key.agentServerPort)
        }
    }

    // MARK: Debug

    /// Outlines the computed cutout to verify hardware alignment.
    var showsGeometryOutline: Bool { didSet { defaults.set(showsGeometryOutline, forKey: Key.geometryOutline) } }
    /// Launch argument only: open (pinned) right after launch.
    let startExpanded: Bool
    /// Launch argument only (Debug): keep secrets in memory, skipping Keychain prompts.
    let usesEphemeralSecureStore: Bool

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults

        func choice<T: RawRepresentable>(_ key: String, _ fallback: T) -> T where T.RawValue == String {
            guard let raw = defaults.string(forKey: key), let value = T(rawValue: raw) else { return fallback }
            return value
        }

        showsMenuBarIcon = defaults.object(forKey: Key.showsMenuBarIcon) as? Bool ?? true
        displayPolicy = choice(Key.displayPolicy, DisplayPolicy.notchDisplay)
        hoverDelayMilliseconds = Self.clamp(defaults.object(forKey: Key.hoverDelay) as? Int ?? 150, to: Self.hoverDelayRange)
        autoCollapse = choice(Key.autoCollapse, AutoCollapseBehavior.pointerExit)

        theme = choice(Key.theme, NotchTheme.classicBlack)
        sizePreset = choice(Key.sizePreset, NotchSizePreset.medium)
        visualizerStyle = choice(Key.visualizerStyle, VisualizerStyle.bars)
        accentColor = choice(Key.accentColor, AccentColorChoice.rose)
        hidesIdlePill = defaults.bool(forKey: Key.hidesIdlePill)

        let storedModules = defaults.data(forKey: Key.modules)
            .flatMap { try? JSONDecoder().decode([ModuleConfiguration].self, from: $0) }
        modules = ModuleConfiguration.reconciled(storedModules ?? ModuleConfiguration.defaults)

        chatModel = choice(Key.chatModel, ChatModelChoice.claudeSonnet)
        chatSystemPrompt = defaults.string(forKey: Key.chatSystemPrompt) ?? Self.defaultSystemPrompt
        agentServerPort = Self.clamp(defaults.object(forKey: Key.agentServerPort) as? Int ?? Self.defaultAgentPort, to: Self.agentPortRange)

        showsGeometryOutline = defaults.bool(forKey: Key.geometryOutline)
        startExpanded = defaults.bool(forKey: Key.startExpanded)
        #if DEBUG
        usesEphemeralSecureStore = defaults.bool(forKey: Key.ephemeralSecureStore)
        #else
        usesEphemeralSecureStore = false
        #endif
    }

    func resetModules() {
        modules = ModuleConfiguration.defaults
    }

    private static func clamp(_ value: Int, to range: ClosedRange<Int>) -> Int {
        min(max(value, range.lowerBound), range.upperBound)
    }
}
