import AppKit
import Foundation
import Observation

nonisolated enum PomodoroPhase: String, Codable, Sendable {
    case focus, shortBreak, longBreak

    var isBreak: Bool { self != .focus }

    var displayName: String {
        switch self {
        case .focus: "Focus"
        case .shortBreak: "Short break"
        case .longBreak: "Long break"
        }
    }
}

/// The timer's state. Running = has an end date; paused = has time remaining; idle = neither.
/// Stored in UserDefaults so a running timer survives a relaunch.
nonisolated struct PomodoroState: Codable, Equatable, Sendable {
    var phase: PomodoroPhase = .focus
    var endDate: Date?
    var pausedRemaining: TimeInterval?
    /// Focus sessions finished in the current cycle (resets after a long break).
    var completedInCycle = 0
    var completedToday = 0
    var todayStamp = PomodoroState.dayStamp(Date())

    var isRunning: Bool { endDate != nil }
    var isPaused: Bool { endDate == nil && pausedRemaining != nil }
    var isIdle: Bool { endDate == nil && pausedRemaining == nil }

    static func dayStamp(_ date: Date) -> String {
        date.formatted(.iso8601.year().month().day())
    }
}

/// Phase durations and cycle length (from Settings → Modules → Pomodoro).
nonisolated struct PomodoroPlan: Equatable, Sendable {
    var focus: TimeInterval
    var shortBreak: TimeInterval
    var longBreak: TimeInterval
    var sessionsBeforeLongBreak: Int

    func duration(of phase: PomodoroPhase) -> TimeInterval {
        switch phase {
        case .focus: focus
        case .shortBreak: shortBreak
        case .longBreak: longBreak
        }
    }
}

/// Pure state transitions, unit-tested.
nonisolated enum PomodoroLogic {
    static func start(_ state: PomodoroState, plan: PomodoroPlan, at now: Date) -> PomodoroState {
        var state = state
        let remaining = state.pausedRemaining ?? plan.duration(of: state.phase)
        state.endDate = now.addingTimeInterval(remaining)
        state.pausedRemaining = nil
        return state
    }

    static func pause(_ state: PomodoroState, at now: Date) -> PomodoroState {
        guard let end = state.endDate else { return state }
        var state = state
        state.pausedRemaining = max(0, end.timeIntervalSince(now))
        state.endDate = nil
        return state
    }

    /// Finishes the current phase (naturally or skipped) and moves to the next one, idle.
    /// Only a focus session that ran to the end counts toward the cycle and today's total.
    static func advance(_ state: PomodoroState, plan: PomodoroPlan, counted: Bool, at now: Date) -> PomodoroState {
        var state = state
        let today = PomodoroState.dayStamp(now)
        if state.todayStamp != today {
            state.todayStamp = today
            state.completedToday = 0
        }
        switch state.phase {
        case .focus:
            if counted {
                state.completedInCycle += 1
                state.completedToday += 1
            }
            state.phase = state.completedInCycle >= plan.sessionsBeforeLongBreak ? .longBreak : .shortBreak
        case .longBreak:
            state.completedInCycle = 0
            state.phase = .focus
        case .shortBreak:
            state.phase = .focus
        }
        state.endDate = nil
        state.pausedRemaining = nil
        return state
    }

    static func remaining(_ state: PomodoroState, plan: PomodoroPlan, at now: Date) -> TimeInterval {
        if let end = state.endDate { return max(0, end.timeIntervalSince(now)) }
        return state.pausedRemaining ?? plan.duration(of: state.phase)
    }

    /// "24:13", or "1:02:00" past an hour.
    static func clock(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded(.up))
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }
}

/// Focus timer with work / break phases, a countdown pill beside the notch, and a chime + pill
/// when a phase ends.
@Observable
final class PomodoroTimer {
    static let stateKey = "notchdeck.pomodoro.state"

    private(set) var state: PomodoroState {
        didSet { save() }
    }

    @ObservationIgnored private let settings: SettingsStore
    @ObservationIgnored private let toasts: NotchToastCenter
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var completionTask: Task<Void, Never>?

    init(settings: SettingsStore, toasts: NotchToastCenter, defaults: UserDefaults = .standard) {
        self.settings = settings
        self.toasts = toasts
        self.defaults = defaults
        state = defaults.data(forKey: Self.stateKey).flatMap { try? JSONDecoder().decode(PomodoroState.self, from: $0) } ?? PomodoroState()
    }

    var plan: PomodoroPlan {
        PomodoroPlan(
            focus: TimeInterval(settings.pomodoroFocusMinutes * 60),
            shortBreak: TimeInterval(settings.pomodoroShortBreakMinutes * 60),
            longBreak: TimeInterval(settings.pomodoroLongBreakMinutes * 60),
            sessionsBeforeLongBreak: settings.pomodoroSessionsBeforeLongBreak
        )
    }

    /// Shown beside the notch while running or paused.
    var isActive: Bool { !state.isIdle }

    /// Called at launch: a phase that ended while NotchDeck was closed moves on quietly.
    func resume() {
        if let end = state.endDate, end <= Date() {
            state = PomodoroLogic.advance(state, plan: plan, counted: state.phase == .focus, at: Date())
        }
        scheduleCompletion()
    }

    // MARK: Controls

    /// The Start / Pause shortcut and the main button.
    func toggle() {
        state.isRunning ? pause() : start()
    }

    func start() {
        state = PomodoroLogic.start(state, plan: plan, at: Date())
        scheduleCompletion()
    }

    func pause() {
        state = PomodoroLogic.pause(state, at: Date())
        completionTask?.cancel()
    }

    /// Ends the current phase without counting it.
    func skip() {
        completionTask?.cancel()
        state = PomodoroLogic.advance(state, plan: plan, counted: false, at: Date())
    }

    /// Back to a fresh focus session; today's total is kept.
    func reset() {
        completionTask?.cancel()
        var fresh = PomodoroState()
        fresh.completedToday = state.todayStamp == PomodoroState.dayStamp(Date()) ? state.completedToday : 0
        state = fresh
    }

    func remaining(at date: Date) -> TimeInterval {
        PomodoroLogic.remaining(state, plan: plan, at: date)
    }

    func progress(at date: Date) -> Double {
        let total = plan.duration(of: state.phase)
        guard total > 0 else { return 0 }
        return 1 - remaining(at: date) / total
    }

    // MARK: Completion

    private func scheduleCompletion() {
        completionTask?.cancel()
        guard let end = state.endDate else { return }
        completionTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(max(0, end.timeIntervalSinceNow)))
            guard !Task.isCancelled else { return }
            self?.phaseEnded()
        }
    }

    private func phaseEnded() {
        let finished = state.phase
        state = PomodoroLogic.advance(state, plan: plan, counted: finished == .focus, at: Date())
        if settings.pomodoroSoundEnabled {
            NSSound(named: finished == .focus ? "Glass" : "Hero")?.play()
        }
        let next = state.phase
        let autoStart = next.isBreak ? settings.pomodoroAutoStartBreaks : settings.pomodoroAutoStartFocus
        let minutes = Int(plan.duration(of: next) / 60)
        toasts.show(LiveToast(.pomodoro(
            title: finished == .focus ? "Focus done" : "Break over",
            detail: autoStart ? "\(next.displayName) · \(minutes) min" : "Start \(next.displayName.lowercased())?",
            isBreak: next.isBreak
        )))
        if autoStart { start() }
    }

    private func save() {
        if let data = try? JSONEncoder().encode(state) { defaults.set(data, forKey: Self.stateKey) }
    }
}
