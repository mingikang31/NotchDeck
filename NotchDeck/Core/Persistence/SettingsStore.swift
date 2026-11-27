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
        static let hoverCloseDelay = "notchdeck.hoverCloseDelayMilliseconds"
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
        static let systemMonitorInterval = "notchdeck.systemMonitor.interval"
        static let systemOverviewStyle = "notchdeck.systemMonitor.overviewStyle"
        static let systemMonitorAccent = "notchdeck.systemMonitor.accent"
        static let agentHookToken = "notchdeck.agentHookToken"
        static let agentChimeEnabled = "notchdeck.agentChimeEnabled"
        static let liveBattery = "notchdeck.live.battery"
        static let liveBluetooth = "notchdeck.live.bluetooth"
        static let liveDownloads = "notchdeck.live.downloads"
        static let pomodoroFocus = "notchdeck.pomodoro.focusMinutes"
        static let pomodoroShortBreak = "notchdeck.pomodoro.shortBreakMinutes"
        static let pomodoroLongBreak = "notchdeck.pomodoro.longBreakMinutes"
        static let pomodoroSessions = "notchdeck.pomodoro.sessionsBeforeLongBreak"
        static let pomodoroAutoStartBreaks = "notchdeck.pomodoro.autoStartBreaks"
        static let pomodoroAutoStartFocus = "notchdeck.pomodoro.autoStartFocus"
        static let pomodoroSound = "notchdeck.pomodoro.sound"
        static let clipboardLimit = "notchdeck.clipboard.limit"
        static let clipboardImages = "notchdeck.clipboard.capturesImages"
        static let worldClockCities = "notchdeck.worldClock.cities"
        static let lyricsEnabled = "notchdeck.media.lyricsEnabled"
        static let lyricsOffset = "notchdeck.media.lyricsOffset"
        static let customModelPrices = "notchdeck.usage.customPrices"
        static let usagePreferences = "notchdeck.usage.preferences"
        static let geometryOutline = "notchdeck.debug.showsGeometryOutline"
        static let startExpanded = "notchdeck.debug.startExpanded"
        static let startModule = "notchdeck.debug.startModule"
        static let ephemeralSecureStore = "notchdeck.debug.ephemeralSecureStore"
    }

    static let hoverDelayRange = 0...500
    static let hoverCloseDelayRange = 0...500
    static let defaultHoverCloseDelay = 200
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
    /// How long the pointer may be outside the open notch before it collapses (0–500 ms, default
    /// 200 ms). Only used when auto-collapse is "When the pointer leaves".
    var hoverCloseDelayMilliseconds: Int {
        didSet {
            let clamped = Self.clamp(hoverCloseDelayMilliseconds, to: Self.hoverCloseDelayRange)
            if clamped != hoverCloseDelayMilliseconds { hoverCloseDelayMilliseconds = clamped }
            defaults.set(clamped, forKey: Key.hoverCloseDelay)
        }
    }
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
    // MARK: System monitor

    /// How often the System tab samples CPU / GPU / memory, in seconds.
    static let systemMonitorIntervals: [Double] = [0.25, 0.5, 1, 2, 5]
    /// Color of the System tab's meters and graphs (same palette as the visualizer; no album art).
    var systemMonitorAccent: AccentColorChoice {
        didSet {
            if systemMonitorAccent == .artwork { systemMonitorAccent = .blue }
            defaults.set(systemMonitorAccent.rawValue, forKey: Key.systemMonitorAccent)
        }
    }
    var systemOverviewStyle: SystemOverviewStyle {
        didSet { defaults.set(systemOverviewStyle.rawValue, forKey: Key.systemOverviewStyle) }
    }
    var systemMonitorInterval: Double {
        didSet {
            let snapped = Self.nearestInterval(to: systemMonitorInterval)
            if snapped != systemMonitorInterval { systemMonitorInterval = snapped }
            defaults.set(snapped, forKey: Key.systemMonitorInterval)
        }
    }

    static func nearestInterval(to value: Double) -> Double {
        systemMonitorIntervals.min { abs($0 - value) < abs($1 - value) } ?? 1
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

    // MARK: Live Activities

    /// Charging / unplugged / low-battery pills.
    var liveBatteryEnabled: Bool { didSet { defaults.set(liveBatteryEnabled, forKey: Key.liveBattery) } }
    /// AirPods / headphone / keyboard connection toasts.
    var liveBluetoothEnabled: Bool { didSet { defaults.set(liveBluetoothEnabled, forKey: Key.liveBluetooth) } }
    /// New files in ~/Downloads.
    var liveDownloadsEnabled: Bool { didSet { defaults.set(liveDownloadsEnabled, forKey: Key.liveDownloads) } }

    // MARK: Pomodoro

    static let pomodoroFocusRange = 5...90
    static let pomodoroShortBreakRange = 1...30
    static let pomodoroLongBreakRange = 5...60
    static let pomodoroSessionsRange = 2...8

    var pomodoroFocusMinutes: Int {
        didSet {
            let clamped = Self.clamp(pomodoroFocusMinutes, to: Self.pomodoroFocusRange)
            if clamped != pomodoroFocusMinutes { pomodoroFocusMinutes = clamped }
            defaults.set(clamped, forKey: Key.pomodoroFocus)
        }
    }
    var pomodoroShortBreakMinutes: Int {
        didSet {
            let clamped = Self.clamp(pomodoroShortBreakMinutes, to: Self.pomodoroShortBreakRange)
            if clamped != pomodoroShortBreakMinutes { pomodoroShortBreakMinutes = clamped }
            defaults.set(clamped, forKey: Key.pomodoroShortBreak)
        }
    }
    var pomodoroLongBreakMinutes: Int {
        didSet {
            let clamped = Self.clamp(pomodoroLongBreakMinutes, to: Self.pomodoroLongBreakRange)
            if clamped != pomodoroLongBreakMinutes { pomodoroLongBreakMinutes = clamped }
            defaults.set(clamped, forKey: Key.pomodoroLongBreak)
        }
    }
    /// Focus sessions before a long break.
    var pomodoroSessionsBeforeLongBreak: Int {
        didSet {
            let clamped = Self.clamp(pomodoroSessionsBeforeLongBreak, to: Self.pomodoroSessionsRange)
            if clamped != pomodoroSessionsBeforeLongBreak { pomodoroSessionsBeforeLongBreak = clamped }
            defaults.set(clamped, forKey: Key.pomodoroSessions)
        }
    }
    var pomodoroAutoStartBreaks: Bool { didSet { defaults.set(pomodoroAutoStartBreaks, forKey: Key.pomodoroAutoStartBreaks) } }
    var pomodoroAutoStartFocus: Bool { didSet { defaults.set(pomodoroAutoStartFocus, forKey: Key.pomodoroAutoStartFocus) } }
    var pomodoroSoundEnabled: Bool { didSet { defaults.set(pomodoroSoundEnabled, forKey: Key.pomodoroSound) } }

    // MARK: Clipboard

    static let clipboardLimits = [10, 25, 50]
    var clipboardHistoryLimit: Int {
        didSet {
            let snapped = Self.clipboardLimits.min { abs($0 - clipboardHistoryLimit) < abs($1 - clipboardHistoryLimit) } ?? 25
            if snapped != clipboardHistoryLimit { clipboardHistoryLimit = snapped }
            defaults.set(snapped, forKey: Key.clipboardLimit)
        }
    }
    var clipboardCapturesImages: Bool { didSet { defaults.set(clipboardCapturesImages, forKey: Key.clipboardImages) } }

    // MARK: World Clock, Lyrics, Usage

    var worldClockCities: [WorldClockCity] {
        didSet { defaults.set(try? JSONEncoder().encode(worldClockCities), forKey: Key.worldClockCities) }
    }
    /// Time-synced lyrics under the collapsed notch (sends track info to lrclib.net). Off by default.
    var lyricsEnabled: Bool { didSet { defaults.set(lyricsEnabled, forKey: Key.lyricsEnabled) } }
    /// Manual lyric timing nudge in seconds (positive = lines appear earlier), −1…+1.
    static let lyricsOffsetRange: ClosedRange<Double> = -1...1
    var lyricsOffset: Double {
        didSet {
            let clamped = min(max((lyricsOffset * 10).rounded() / 10, Self.lyricsOffsetRange.lowerBound), Self.lyricsOffsetRange.upperBound)
            if clamped != lyricsOffset { lyricsOffset = clamped }
            defaults.set(clamped, forKey: Key.lyricsOffset)
        }
    }
    /// The user's own per-model prices (override the built-in table; `*` suffix = prefix match).
    /// What the Usage tab and the Agent Hooks strip show.
    var usagePreferences: UsagePreferences {
        didSet { defaults.set(try? JSONEncoder().encode(usagePreferences), forKey: Key.usagePreferences) }
    }
    var customModelPrices: [ModelPrice] {
        didSet { defaults.set(try? JSONEncoder().encode(customModelPrices), forKey: Key.customModelPrices) }
    }

    // MARK: Debug

    /// Outlines the computed cutout to verify hardware alignment.
    var showsGeometryOutline: Bool { didSet { defaults.set(showsGeometryOutline, forKey: Key.geometryOutline) } }
    /// Launch argument only: open (pinned) right after launch.
    let startExpanded: Bool
    /// Launch argument only: with `startExpanded`, open on this module (raw value, e.g. `systemMonitor`).
    let startModule: NotchModule?
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
        hoverCloseDelayMilliseconds = Self.clamp(
            defaults.object(forKey: Key.hoverCloseDelay) as? Int ?? Self.defaultHoverCloseDelay, to: Self.hoverCloseDelayRange
        )
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
        systemOverviewStyle = choice(Key.systemOverviewStyle, SystemOverviewStyle.cards)
        let storedMonitorAccent = choice(Key.systemMonitorAccent, AccentColorChoice.blue)
        systemMonitorAccent = storedMonitorAccent == .artwork ? .blue : storedMonitorAccent
        systemMonitorInterval = Self.nearestInterval(to: defaults.object(forKey: Key.systemMonitorInterval) as? Double ?? 1)
        agentHookToken = defaults.string(forKey: Key.agentHookToken) ?? ""
        agentChimeEnabled = defaults.object(forKey: Key.agentChimeEnabled) as? Bool ?? true
        agentServerPort = Self.clamp(defaults.object(forKey: Key.agentServerPort) as? Int ?? Self.defaultAgentPort, to: Self.agentPortRange)

        liveBatteryEnabled = defaults.object(forKey: Key.liveBattery) as? Bool ?? true
        liveBluetoothEnabled = defaults.object(forKey: Key.liveBluetooth) as? Bool ?? true
        liveDownloadsEnabled = defaults.object(forKey: Key.liveDownloads) as? Bool ?? true
        pomodoroFocusMinutes = Self.clamp(defaults.object(forKey: Key.pomodoroFocus) as? Int ?? 25, to: Self.pomodoroFocusRange)
        pomodoroShortBreakMinutes = Self.clamp(defaults.object(forKey: Key.pomodoroShortBreak) as? Int ?? 5, to: Self.pomodoroShortBreakRange)
        pomodoroLongBreakMinutes = Self.clamp(defaults.object(forKey: Key.pomodoroLongBreak) as? Int ?? 15, to: Self.pomodoroLongBreakRange)
        pomodoroSessionsBeforeLongBreak = Self.clamp(defaults.object(forKey: Key.pomodoroSessions) as? Int ?? 4, to: Self.pomodoroSessionsRange)
        pomodoroAutoStartBreaks = defaults.object(forKey: Key.pomodoroAutoStartBreaks) as? Bool ?? true
        pomodoroAutoStartFocus = defaults.object(forKey: Key.pomodoroAutoStartFocus) as? Bool ?? false
        pomodoroSoundEnabled = defaults.object(forKey: Key.pomodoroSound) as? Bool ?? true
        let storedLimit = defaults.object(forKey: Key.clipboardLimit) as? Int ?? 25
        clipboardHistoryLimit = Self.clipboardLimits.contains(storedLimit) ? storedLimit : 25
        clipboardCapturesImages = defaults.object(forKey: Key.clipboardImages) as? Bool ?? true

        worldClockCities = defaults.data(forKey: Key.worldClockCities)
            .flatMap { try? JSONDecoder().decode([WorldClockCity].self, from: $0) } ?? CityCatalog.defaults
        lyricsEnabled = defaults.bool(forKey: Key.lyricsEnabled)
        lyricsOffset = min(max(defaults.double(forKey: Key.lyricsOffset), Self.lyricsOffsetRange.lowerBound), Self.lyricsOffsetRange.upperBound)
        usagePreferences = defaults.data(forKey: Key.usagePreferences)
            .flatMap { try? JSONDecoder().decode(UsagePreferences.self, from: $0) } ?? UsagePreferences()
        customModelPrices = defaults.data(forKey: Key.customModelPrices)
            .flatMap { try? JSONDecoder().decode([ModelPrice].self, from: $0) } ?? []

        showsGeometryOutline = defaults.bool(forKey: Key.geometryOutline)
        startExpanded = defaults.bool(forKey: Key.startExpanded)
        startModule = defaults.string(forKey: Key.startModule).flatMap(NotchModule.init(rawValue:))
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
