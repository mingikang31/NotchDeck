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
        static let hiddenCalendarIDs = "notchdeck.calendar.hiddenIDs"
        static let calendarRange = "notchdeck.calendar.range"
        static let calendarShowsAllDay = "notchdeck.calendar.showsAllDay"
        static let chatModel = "notchdeck.chatModel"
        static let permissionsPerSession = "notchdeck.privacy.permissionsPerSession"
        static let calendarWasConnected = "notchdeck.calendar.wasConnected"
        static let chatSystemPrompt = "notchdeck.chatSystemPrompt"
        static let customEndpointURL = "notchdeck.chat.customEndpointURL"
        static let handAddedModels = "notchdeck.chat.handAddedModels"
        static let agentServerPort = "notchdeck.agentServerPort"
        static let agentHookToken = "notchdeck.agentHookToken"
        static let agentChimeEnabled = "notchdeck.agentChimeEnabled"
        static let geometryOutline = "notchdeck.debug.showsGeometryOutline"
        static let startExpanded = "notchdeck.debug.startExpanded"
        static let ephemeralSecureStore = "notchdeck.debug.ephemeralSecureStore"
    }

    static let hoverDelayRange = 0...500
    static let agentPortRange = 1024...65535
    /// Outside macOS's ephemeral range (49152–65535), where system services and VPN clients bind
    /// (e.g. Cisco AnyConnect's vpnagentd holds 127.0.0.1:49152).
    static let defaultAgentPort = 47823
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

    // MARK: Privacy

    /// Permissions (Automation, Calendars, …) last only while NotchDeck runs; it asks again next launch.
    var permissionsPerSession: Bool { didSet { defaults.set(permissionsPerSession, forKey: Key.permissionsPerSession) } }
    /// The user connected their calendar at some point; with per-session permissions NotchDeck
    /// re-asks for Calendar access at launch instead of waiting for "Connect Calendar".
    var calendarWasConnected: Bool { didSet { defaults.set(calendarWasConnected, forKey: Key.calendarWasConnected) } }

    // MARK: Calendar

    /// Calendars the user turned off. Stored as an exclusion list so newly added calendars show by default.
    var hiddenCalendarIDs: Set<String> {
        didSet { defaults.set(hiddenCalendarIDs.sorted(), forKey: Key.hiddenCalendarIDs) }
    }
    var calendarRange: CalendarRange { didSet { defaults.set(calendarRange.rawValue, forKey: Key.calendarRange) } }
    var calendarShowsAllDay: Bool { didSet { defaults.set(calendarShowsAllDay, forKey: Key.calendarShowsAllDay) } }

    // MARK: AI & Agents

    /// Default model for new chats (provider + exact model ID).
    var chatModel: ChatModelRef { didSet { defaults.set(chatModel.storageKey, forKey: Key.chatModel) } }
    var chatSystemPrompt: String { didSet { defaults.set(chatSystemPrompt, forKey: Key.chatSystemPrompt) } }
    /// Optional OpenAI-compatible endpoint (base URL ending in /v1, e.g. a local server).
    var customEndpointURL: String { didSet { defaults.set(customEndpointURL, forKey: Key.customEndpointURL) } }
    /// Model IDs the user typed in (beyond what the providers' model lists return).
    var handAddedModels: [ChatModelRef] {
        didSet { defaults.set(handAddedModels.map(\.storageKey), forKey: Key.handAddedModels) }
    }
    /// Shared secret the installed Claude Code hook sends; requests without it are refused.
    var agentHookToken: String { didSet { defaults.set(agentHookToken, forKey: Key.agentHookToken) } }
    /// Chime when Claude Code finishes a task.
    var agentChimeEnabled: Bool { didSet { defaults.set(agentChimeEnabled, forKey: Key.agentChimeEnabled) } }
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

        permissionsPerSession = defaults.object(forKey: Key.permissionsPerSession) as? Bool ?? true
        calendarWasConnected = defaults.bool(forKey: Key.calendarWasConnected)

        hiddenCalendarIDs = Set(defaults.stringArray(forKey: Key.hiddenCalendarIDs) ?? [])
        calendarRange = choice(Key.calendarRange, CalendarRange.next3Days)
        calendarShowsAllDay = defaults.object(forKey: Key.calendarShowsAllDay) as? Bool ?? true

        chatModel = defaults.string(forKey: Key.chatModel).flatMap(ChatModelRef.init(storageKey:)) ?? .defaultModel
        chatSystemPrompt = defaults.string(forKey: Key.chatSystemPrompt) ?? Self.defaultSystemPrompt
        customEndpointURL = defaults.string(forKey: Key.customEndpointURL) ?? ""
        handAddedModels = (defaults.stringArray(forKey: Key.handAddedModels) ?? []).compactMap(ChatModelRef.init(storageKey:))
        agentHookToken = defaults.string(forKey: Key.agentHookToken) ?? ""
        agentChimeEnabled = defaults.object(forKey: Key.agentChimeEnabled) as? Bool ?? true
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
