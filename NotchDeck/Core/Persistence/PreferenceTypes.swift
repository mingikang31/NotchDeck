import SwiftUI

/// Which displays get a notch surface.
nonisolated enum DisplayPolicy: String, CaseIterable, Identifiable, Sendable {
    /// The built-in notched display, or the menu-bar display if no notch exists.
    case notchDisplay
    /// Moves to whichever display the pointer is on.
    case followActiveScreen
    case allDisplays

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .notchDisplay: "Built-in Notch Display Only"
        case .followActiveScreen: "Follow Active Screen"
        case .allDisplays: "All Displays"
        }
    }
}

nonisolated enum AutoCollapseBehavior: String, CaseIterable, Identifiable, Sendable {
    /// Collapse shortly after the pointer leaves the expanded notch.
    case pointerExit
    /// Stay open until a click outside, Escape, or the toggle shortcut.
    case clickOutside

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .pointerExit: "When the pointer leaves"
        case .clickOutside: "When clicking outside"
        }
    }
}

nonisolated enum VisualizerStyle: String, CaseIterable, Identifiable, Sendable {
    case bars, wave, off

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .bars: "Bars"
        case .wave: "Wave"
        case .off: "Off"
        }
    }
}

nonisolated enum AccentColorChoice: String, CaseIterable, Identifiable, Sendable {
    case rose, violet, blue, teal, amber, graphite

    var id: String { rawValue }

    var displayName: String { rawValue.capitalized }

    var color: Color { gradient[0] }

    /// Two-stop gradient used by the ambient glow and visualizer.
    var gradient: [Color] {
        switch self {
        case .rose: [Color(red: 1.00, green: 0.36, blue: 0.52), Color(red: 1.00, green: 0.55, blue: 0.35)]
        case .violet: [Color(red: 0.62, green: 0.40, blue: 1.00), Color(red: 1.00, green: 0.36, blue: 0.72)]
        case .blue: [Color(red: 0.25, green: 0.56, blue: 1.00), Color(red: 0.40, green: 0.85, blue: 1.00)]
        case .teal: [Color(red: 0.16, green: 0.80, blue: 0.70), Color(red: 0.35, green: 0.62, blue: 1.00)]
        case .amber: [Color(red: 1.00, green: 0.70, blue: 0.20), Color(red: 1.00, green: 0.42, blue: 0.30)]
        case .graphite: [Color(white: 0.72), Color(white: 0.42)]
        }
    }
}

/// How far ahead the Calendar module looks.
nonisolated enum CalendarRange: String, CaseIterable, Identifiable, Sendable {
    case next24Hours, next3Days, next7Days

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .next24Hours: "Next 24 hours"
        case .next3Days: "Next 3 days"
        case .next7Days: "Next 7 days"
        }
    }

    var interval: TimeInterval {
        switch self {
        case .next24Hours: 24 * 3600
        case .next3Days: 3 * 24 * 3600
        case .next7Days: 7 * 24 * 3600
        }
    }
}

nonisolated enum ChatProvider: String, CaseIterable, Codable, Sendable {
    case anthropic, gemini, openAICompatible
}

/// Every notch module, in default tab order.
nonisolated enum NotchModule: String, CaseIterable, Codable, Identifiable, Sendable {
    case media, fileTray, aiChat, agentHooks, calendar, liveActivities, pomodoro, todos, clipboard, mirror

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .media: "Media"
        case .fileTray: "File Tray"
        case .aiChat: "AI Chat"
        case .agentHooks: "Agent Hooks"
        case .calendar: "Calendar"
        case .liveActivities: "Live Activities"
        case .pomodoro: "Pomodoro"
        case .todos: "To-Dos"
        case .clipboard: "Clipboard"
        case .mirror: "Mirror"
        }
    }

    var symbolName: String {
        switch self {
        case .media: "play.circle.fill"
        case .fileTray: "tray.fill"
        case .aiChat: "sparkles"
        case .agentHooks: "terminal.fill"
        case .calendar: "calendar"
        case .liveActivities: "bolt.fill"
        case .pomodoro: "timer"
        case .todos: "checklist"
        case .clipboard: "doc.on.clipboard"
        case .mirror: "camera.fill"
        }
    }

    /// Latest roadmap phase that has shipped; modules at or below it are functional.
    static let shippedThroughPhase = 4

    var isAvailable: Bool { phase <= Self.shippedThroughPhase }

    /// Roadmap phase in which the module ships.
    var phase: Int {
        switch self {
        case .media, .fileTray, .calendar: 3
        case .aiChat: 4
        case .agentHooks: 5
        case .liveActivities, .pomodoro, .todos, .clipboard, .mirror: 6
        }
    }
}

nonisolated struct ModuleConfiguration: Codable, Equatable, Identifiable, Sendable {
    var module: NotchModule
    var isEnabled: Bool

    var id: NotchModule { module }

    static let defaults: [ModuleConfiguration] = NotchModule.allCases.map { ModuleConfiguration(module: $0, isEnabled: true) }

    /// Keeps the stored order, drops unknown entries, and appends modules added in newer versions.
    static func reconciled(_ stored: [ModuleConfiguration]) -> [ModuleConfiguration] {
        var seen = Set<NotchModule>()
        var result = stored.filter { seen.insert($0.module).inserted }
        for module in NotchModule.allCases where !seen.contains(module) {
            result.append(ModuleConfiguration(module: module, isEnabled: true))
        }
        return result
    }
}
