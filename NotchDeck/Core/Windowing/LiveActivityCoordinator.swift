import Foundation
import Observation
import SwiftUI

/// What the collapsed notch shows in its "wings" beside the cutout.
nonisolated enum LiveActivity: Equatable, Sendable {
    /// Album art on the left, visualizer on the right.
    case nowPlaying
    /// Countdown on the left, event title on the right.
    case upcomingEvent(id: String)

    var wingWidth: CGFloat {
        switch self {
        case .nowPlaying: 34
        case .upcomingEvent: 92
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

    /// Bumped every 30 s so time-based priorities re-evaluate.
    private var clock = Date()
    @ObservationIgnored private var tickTask: Task<Void, Never>?

    init(media: NowPlayingStore, calendar: CalendarStore, settings: SettingsStore, license: LicenseManager) {
        self.media = media
        self.calendar = calendar
        self.settings = settings
        self.license = license
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
        let event = enabled.contains(.calendar) ? calendar.nextEvent(at: clock) : nil
        return Self.resolve(
            isMediaPlaying: enabled.contains(.media) && media.isPlaying,
            event: event.map { ($0.id, $0.start.timeIntervalSince(clock), $0.isOngoing(at: clock)) }
        )
    }

    var wingWidth: CGFloat { current?.wingWidth ?? 0 }

    /// Priority: an ongoing or imminent (≤15 min) event, then playing media, then an event within the hour.
    static func resolve(isMediaPlaying: Bool, event: (id: String, startsIn: TimeInterval, isOngoing: Bool)?) -> LiveActivity? {
        if let event, event.isOngoing || event.startsIn <= urgentEventWindow {
            // Keep an ongoing meeting up for its first 10 minutes only, then yield to music.
            if !event.isOngoing || event.startsIn > -10 * 60 || !isMediaPlaying {
                return .upcomingEvent(id: event.id)
            }
        }
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
        }
    }

    private var colors: [Color] {
        media.palette.isEmpty ? settings.accentColor.gradient : media.palette
    }
}
