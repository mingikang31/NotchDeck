import SwiftUI

enum PomodoroPalette {
    static let focus = Color(red: 1.00, green: 0.42, blue: 0.35)
    static let rest = Color(red: 0.30, green: 0.80, blue: 0.62)

    static func color(for phase: PomodoroPhase) -> Color { phase.isBreak ? rest : focus }
}

/// Expanded Pomodoro: progress ring with the countdown, controls, and today's sessions.
struct PomodoroModuleView: View {
    let tokens: ThemeTokens

    @Environment(PomodoroTimer.self) private var timer
    @Environment(SettingsStore.self) private var settings

    var body: some View {
        let state = timer.state
        let color = PomodoroPalette.color(for: state.phase)
        TimelineView(.periodic(from: .now, by: 1)) { context in
            HStack(spacing: 18) {
                ZStack {
                    Circle().stroke(color.opacity(0.18), lineWidth: 6)
                    Circle()
                        .trim(from: 0, to: state.isIdle ? 0 : timer.progress(at: context.date))
                        .stroke(color, style: StrokeStyle(lineWidth: 6, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                        .animation(.linear(duration: 1), value: context.date)
                    VStack(spacing: 0) {
                        Text(PomodoroLogic.clock(timer.remaining(at: context.date)))
                            .font(.system(size: 19, weight: .semibold).monospacedDigit())
                            .contentTransition(.numericText(countsDown: true))
                        Text(state.isPaused ? "Paused" : state.phase.isBreak ? "Break" : "Focus")
                            .font(.system(size: 9.5, weight: .medium))
                            .foregroundStyle(state.isPaused ? tokens.secondaryText : color)
                    }
                }
                .frame(width: 86, height: 86)

                VStack(alignment: .leading, spacing: 6) {
                    Text(title(state))
                        .font(.system(size: 14, weight: .semibold))
                    Text(status(state, now: context.date))
                        .font(.system(size: 11))
                        .foregroundStyle(tokens.secondaryText)
                    HStack(spacing: 6) {
                        NotchPillButton(
                            title: state.isRunning ? "Pause" : state.isPaused ? "Resume" : "Start",
                            symbol: state.isRunning ? "pause.fill" : "play.fill",
                            tokens: tokens, prominent: true
                        ) { timer.toggle() }
                        NotchPillButton(title: "Skip", symbol: "forward.end.fill", tokens: tokens) { timer.skip() }
                            .help(state.phase.isBreak ? "End the break now" : "End this focus session without counting it")
                        NotchPillButton(title: "Reset", symbol: "arrow.counterclockwise", tokens: tokens) { timer.reset() }
                            .disabled(state.isIdle && state.phase == .focus && state.completedInCycle == 0)
                    }
                    .padding(.top, 2)
                }

                Spacer(minLength: 8)

                VStack(alignment: .trailing, spacing: 4) {
                    Text("\(todayCount(state, now: context.date))")
                        .font(.system(size: 22, weight: .semibold).monospacedDigit())
                    Text("focus sessions today")
                        .font(.system(size: 9.5))
                        .foregroundStyle(tokens.secondaryText)
                    HStack(spacing: 4) {
                        ForEach(0..<settings.pomodoroSessionsBeforeLongBreak, id: \.self) { index in
                            Circle()
                                .fill(index < state.completedInCycle ? PomodoroPalette.focus : tokens.controlFill)
                                .frame(width: 7, height: 7)
                        }
                    }
                    .help("Sessions until a long break")
                }
            }
        }
    }

    private func title(_ state: PomodoroState) -> String {
        guard state.phase == .focus else { return state.phase.displayName }
        let session = min(state.completedInCycle + 1, settings.pomodoroSessionsBeforeLongBreak)
        return "Focus · \(session) of \(settings.pomodoroSessionsBeforeLongBreak)"
    }

    private func status(_ state: PomodoroState, now: Date) -> String {
        if let end = state.endDate { return "Ends at \(end.formatted(date: .omitted, time: .shortened))" }
        if state.isPaused { return "Paused. Resume when you're ready." }
        let minutes = Int(timer.plan.duration(of: state.phase) / 60)
        return "Ready · \(minutes) min"
    }

    private func todayCount(_ state: PomodoroState, now: Date) -> Int {
        state.todayStamp == PomodoroState.dayStamp(now) ? state.completedToday : 0
    }
}
