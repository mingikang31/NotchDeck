import Foundation
import Observation
import SwiftUI

/// What the collapsed notch shows in its "wings" beside the cutout.
nonisolated enum LiveActivity: Equatable, Sendable {
    /// Album art on the left, visualizer on the right.
    case nowPlaying
    /// Countdown on the left, event title on the right.
    case upcomingEvent(id: String)
    /// Claude Code is waiting for an approval (highest priority).
    case agentApproval(count: Int)
    /// Brief pulse after a Claude Code task finishes.
    case agentFinished
    /// A few seconds of charging / AirPods / download / Pomodoro news.
    case toast(LiveToast)
    /// The Pomodoro countdown, while running or paused.
    case pomodoro

    var wingWidth: CGFloat {
        switch self {
        case .nowPlaying: 34
        case .pomodoro: 78
        case .upcomingEvent, .agentApproval, .agentFinished: 92
        case .toast: 104
        }
    }
}

/// Decides which live activity owns the collapsed pill.
@Observable
final class LiveActivityCoordinator {
    /// Imminent meetings win over music; further-out ones only show when nothing plays.
    static let urgentEventWindow: TimeInterval = 15 * 60
    static let eventWindow: TimeInterval = 60 * 60

    @ObservationIgnored private let media: NowPlayingStore
    @ObservationIgnored private let calendar: CalendarStore
    @ObservationIgnored private let settings: SettingsStore
    @ObservationIgnored private let license: LicenseManager
    @ObservationIgnored private let agentHooks: AgentHookStore
    @ObservationIgnored private let toasts: NotchToastCenter
    @ObservationIgnored private let pomodoro: PomodoroTimer

    /// Bumped every 30 s so time-based priorities re-evaluate.
    private var clock = Date()
    @ObservationIgnored private var tickTask: Task<Void, Never>?

    init(
        media: NowPlayingStore, calendar: CalendarStore, settings: SettingsStore, license: LicenseManager,
        agentHooks: AgentHookStore, toasts: NotchToastCenter, pomodoro: PomodoroTimer
    ) {
        self.media = media
        self.calendar = calendar
        self.settings = settings
        self.license = license
        self.agentHooks = agentHooks
        self.toasts = toasts
        self.pomodoro = pomodoro
    }

    func start() {
        tickTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30))
                self?.clock = Date()
            }
        }
    }

    var current: LiveActivity? {
        guard license.isUnlocked else { return nil }
        let enabled = Set(settings.enabledModules)
        if enabled.contains(.agentHooks) {
            if !agentHooks.pending.isEmpty { return .agentApproval(count: agentHooks.pending.count) }
            if agentHooks.lastFinished != nil { return .agentFinished }
        }
        if let toast = toasts.current, enabled.contains(toast.module) { return .toast(toast) }
        let event = enabled.contains(.calendar) ? calendar.nextEvent(at: clock) : nil
        return Self.resolve(
            isMediaPlaying: enabled.contains(.media) && media.isPlaying,
            event: event.map { ($0.id, $0.start.timeIntervalSince(clock), $0.isOngoing(at: clock)) },
            isPomodoroActive: enabled.contains(.pomodoro) && pomodoro.isActive
        )
    }

    var wingWidth: CGFloat { current?.wingWidth ?? 0 }

    /// Priority: an ongoing or imminent (≤15 min) event, then a running Pomodoro, then playing media,
    /// then an event within the hour. (Agent requests and toasts are checked before this.)
    static func resolve(
        isMediaPlaying: Bool,
        event: (id: String, startsIn: TimeInterval, isOngoing: Bool)?,
        isPomodoroActive: Bool = false
    ) -> LiveActivity? {
        if let event, event.isOngoing || event.startsIn <= urgentEventWindow {
            // Keep an ongoing meeting up for its first 10 minutes only, then yield to music.
            if !event.isOngoing || event.startsIn > -10 * 60 || !isMediaPlaying {
                return .upcomingEvent(id: event.id)
            }
        }
        if isPomodoroActive { return .pomodoro }
        if isMediaPlaying { return .nowPlaying }
        if let event, event.startsIn <= eventWindow { return .upcomingEvent(id: event.id) }
        return nil
    }
}

/// Content of the collapsed wings: laid out around the (invisible) hardware cutout.
struct LiveActivityWings: View {
    let activity: LiveActivity
    let cutoutWidth: CGFloat
    let wing: CGFloat
    let height: CGFloat

    @Environment(NowPlayingStore.self) private var media
    @Environment(CalendarStore.self) private var calendar
    @Environment(SettingsStore.self) private var settings
    @Environment(AgentHookStore.self) private var agentHooks
    @Environment(PomodoroTimer.self) private var pomodoro

    var body: some View {
        HStack(spacing: 0) {
            leading.frame(width: wing, height: height)
            Color.clear.frame(width: cutoutWidth, height: height)
            trailing.frame(width: wing, height: height)
        }
        .foregroundStyle(.white)
    }

    @ViewBuilder
    private var leading: some View {
        switch activity {
        case .nowPlaying:
            ArtworkView(image: media.artwork, glowColors: colors, glowOpacity: 0, size: min(20, height - 8))
                .frame(maxWidth: .infinity, alignment: .center)
        case .upcomingEvent:
            if let event = calendar.nextEvent() {
                TimelineView(.periodic(from: .now, by: 30)) { context in
                    HStack(spacing: 4) {
                        Image(systemName: event.meetingLink == nil ? "calendar" : "video.fill")
                            .font(.system(size: 9, weight: .bold))
                        Text(event.countdown(from: context.date))
                            .font(.system(size: 11, weight: .semibold).monospacedDigit())
                    }
                    .foregroundStyle(event.isOngoing(at: context.date) ? Color.green : Color.white)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.leading, 10)
                }
            }
        case .agentApproval(let count):
            HStack(spacing: 4) {
                Image(systemName: "hand.raised.fill").font(.system(size: 9, weight: .bold))
                Text(count > 1 ? "\(count) waiting" : "Approve?").font(.system(size: 11, weight: .semibold))
            }
            .foregroundStyle(.orange)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.leading, 10)
        case .agentFinished:
            HStack(spacing: 4) {
                Image(systemName: "checkmark.circle.fill").font(.system(size: 10, weight: .bold))
                Text("Done").font(.system(size: 11, weight: .semibold))
            }
            .foregroundStyle(.green)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.leading, 10)
        case .toast(let toast):
            ToastWing(toast: toast, side: .leading)
        case .pomodoro:
            TimelineView(.periodic(from: .now, by: 1)) { context in
                HStack(spacing: 4) {
                    Image(systemName: pomodoro.state.isPaused ? "pause.fill" : "timer")
                        .font(.system(size: 9, weight: .bold))
                    Text(PomodoroLogic.clock(pomodoro.remaining(at: context.date)))
                        .font(.system(size: 11, weight: .semibold).monospacedDigit())
                }
                .foregroundStyle(pomodoro.state.isPaused ? Color.white.opacity(0.6) : PomodoroPalette.color(for: pomodoro.state.phase))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.leading, 10)
            }
        }
    }

    @ViewBuilder
    private var trailing: some View {
        switch activity {
        case .nowPlaying:
            AudioVisualizer(isPlaying: media.isPlaying, style: settings.visualizerStyle == .off ? .bars : settings.visualizerStyle, colors: colors)
                .frame(width: 16, height: min(14, height - 12))
                .frame(maxWidth: .infinity, alignment: .center)
        case .upcomingEvent:
            Text(calendar.nextEvent()?.title ?? "")
                .font(.system(size: 11, weight: .medium))
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .trailing)
                .padding(.trailing, 10)
        case .agentApproval:
            Text(agentHooks.current?.toolName ?? "Claude")
                .font(.system(size: 11, weight: .medium))
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .trailing)
                .padding(.trailing, 10)
        case .agentFinished:
            Text(agentHooks.lastFinished?.project ?? "Agent")
                .font(.system(size: 11, weight: .medium))
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .trailing)
                .padding(.trailing, 10)
        case .toast(let toast):
            ToastWing(toast: toast, side: .trailing)
        case .pomodoro:
            Text(pomodoro.state.phase.isBreak ? "Break" : "Focus")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(pomodoro.state.isPaused ? Color.white.opacity(0.6) : Color.white)
                .frame(maxWidth: .infinity, alignment: .trailing)
                .padding(.trailing, 10)
        }
    }

    private var colors: [Color] {
        media.palette.isEmpty ? settings.accentColor.gradient : media.palette
    }
}

/// One half of a toast pill: icon + headline on the left, detail on the right.
private struct ToastWing: View {
    enum Side { case leading, trailing }

    let toast: LiveToast
    let side: Side

    var body: some View {
        Group {
            if side == .leading {
                HStack(spacing: 4) {
                    Image(systemName: content.symbol).font(.system(size: 10, weight: .bold))
                    Text(content.headline)
                        .font(.system(size: 11, weight: .semibold).monospacedDigit())
                        .lineLimit(1)
                }
                .foregroundStyle(content.tint)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.leading, 10)
            } else {
                Text(content.detail)
                    .font(.system(size: 11, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .padding(.trailing, 10)
            }
        }
        .id(toast.id)
        .transition(.opacity)
    }

    private var content: (symbol: String, headline: String, detail: String, tint: Color) {
        switch toast.kind {
        case .charging(let percent):
            ("bolt.fill", "\(percent)%", "Charging", NotchStatusColor.good)
        case .onBattery(let percent, let minutes):
            ("battery.75percent", "\(percent)%", minutes.map { "\(BatteryStatus.duration($0)) left" } ?? "On battery", .white)
        case .lowBattery(let percent):
            ("battery.25percent", "\(percent)%", "Low battery", percent <= 10 ? NotchStatusColor.critical : NotchStatusColor.warning)
        case .charged:
            ("battery.100percent.bolt", "100%", "Charged", NotchStatusColor.good)
        case .deviceConnected(let name, let symbol, let battery):
            (symbol, battery.map { "\($0)%" } ?? "On", name, .white)
        case .download(let name):
            ("arrow.down.circle.fill", "Saved", name, Color(red: 0.25, green: 0.62, blue: 1.0))
        case .pomodoro(let title, let detail, let isBreak):
            (isBreak ? "cup.and.saucer.fill" : "timer", title, detail, isBreak ? PomodoroPalette.rest : PomodoroPalette.focus)
        }
    }
}
