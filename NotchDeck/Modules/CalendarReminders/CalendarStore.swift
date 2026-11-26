import AppKit
import EventKit
import Observation
import SwiftUI

/// A calendar event reduced to what the notch shows.
nonisolated struct UpcomingEvent: Identifiable, Equatable, Sendable {
    var id: String
    var title: String
    var start: Date
    var end: Date
    var isAllDay = false
    var calendarColor: ArtworkPalette.RGB?
    var calendarTitle: String?
    var location: String?
    var meetingLink: MeetingLink?

    func isOngoing(at date: Date) -> Bool { start <= date && date < end }

    /// Collapsed-pill / row countdown: "Now", "In 12m", "In 1h 05m", a clock time, or "All day".
    func countdown(from date: Date) -> String {
        if isAllDay { return "All day" }
        if isOngoing(at: date) { return "Now" }
        let minutes = Int((start.timeIntervalSince(date) / 60).rounded(.up))
        if minutes < 60 { return "In \(max(minutes, 1))m" }
        if minutes < 180 { return String(format: "In %dh %02dm", minutes / 60, minutes % 60) }
        return start.formatted(date: .omitted, time: .shortened)
    }
}

/// A calendar the user can show or hide (Settings → Modules → Calendar).
nonisolated struct CalendarInfo: Identifiable, Equatable, Sendable {
    var id: String
    var title: String
    var sourceTitle: String
    var color: ArtworkPalette.RGB?
}

/// One day's worth of events for the grouped list.
nonisolated struct EventDay: Identifiable, Equatable, Sendable {
    var id: Date { day }
    var day: Date
    var title: String
    var events: [UpcomingEvent]
}

/// EventKit access, the user's calendar selection, and upcoming events.
///
/// Freshness: EventKit posts `EKEventStoreChanged` whenever the local database changes; on top of
/// that NotchDeck asks remote accounts (iCloud, Google, Exchange) to re-sync every 5 minutes, on
/// wake, and on demand, and re-reads every minute so countdowns and "next event" roll over.
/// Access is requested only when the user asks, never at launch.
@Observable
final class CalendarStore {
    enum Access: Equatable { case notDetermined, granted, denied }

    private(set) var access: Access = .notDetermined
    private(set) var events: [UpcomingEvent] = []
    private(set) var calendars: [CalendarInfo] = []
    private(set) var lastRefreshed: Date?

    @ObservationIgnored private var store = EKEventStore()
    @ObservationIgnored private let settings: SettingsStore
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private var tickTask: Task<Void, Never>?
    @ObservationIgnored private var syncTask: Task<Void, Never>?
    @ObservationIgnored private var permissionWatchTask: Task<Void, Never>?
    @ObservationIgnored private(set) var isActive = false
    @ObservationIgnored private var observingSettings = false

    static let maximumEvents = 60
    private static let remoteSyncInterval: Duration = .seconds(5 * 60)

    init(settings: SettingsStore) {
        self.settings = settings
    }

    // MARK: Derived

    /// The event for the collapsed banner: the ongoing timed one, else the next timed one.
    func nextEvent(at date: Date = Date()) -> UpcomingEvent? {
        Self.nextTimedEvent(in: events, at: date)
    }

    static func nextTimedEvent(in events: [UpcomingEvent], at date: Date) -> UpcomingEvent? {
        events.first { !$0.isAllDay && $0.end > date }
    }

    /// Events grouped by day: "Today", "Tomorrow", then "Wed, Nov 27".
    func eventDays(now: Date = Date()) -> [EventDay] {
        Self.groupByDay(events, now: now)
    }

    static func groupByDay(_ events: [UpcomingEvent], now: Date, calendar: Calendar = .current) -> [EventDay] {
        let today = calendar.startOfDay(for: now)
        var groups: [Date: [UpcomingEvent]] = [:]
        for event in events {
            // Multi-day / ongoing events are listed under today rather than their start day.
            let day = max(calendar.startOfDay(for: event.start), today)
            groups[day, default: []].append(event)
        }
        return groups.keys.sorted().map { day in
            let title: String
            if calendar.isDate(day, inSameDayAs: today) {
                title = "Today"
            } else if let tomorrow = calendar.date(byAdding: .day, value: 1, to: today), calendar.isDate(day, inSameDayAs: tomorrow) {
                title = "Tomorrow"
            } else {
                title = day.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day())
            }
            // All-day events first, then by start time.
            let sorted = groups[day, default: []].sorted { lhs, rhs in
                lhs.isAllDay != rhs.isAllDay ? lhs.isAllDay : lhs.start < rhs.start
            }
            return EventDay(day: day, title: title, events: sorted)
        }
    }

    var visibleCalendarCount: Int {
        calendars.filter { !settings.hiddenCalendarIDs.contains($0.id) }.count
    }

    // MARK: Lifecycle

    func setActive(_ active: Bool) {
        guard active != isActive else { return }
        isActive = active
        if active {
            observeStore()
            let wake = NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.syncNow() }
            }
            observers.append(wake)
            tickTask = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(60))
                    self?.refresh()
                }
            }
            syncTask = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: Self.remoteSyncInterval)
                    self?.syncNow()
                }
            }
            // While access is missing, re-check silently so allowing Calendars in System Settings
            // (or answering a late prompt) takes effect without a relaunch.
            permissionWatchTask = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: SessionPermissions.recheckInterval)
                    self?.recheckAccess()
                }
            }
            if !observingSettings {
                observingSettings = true
                observeContinuously({ [weak self] in
                    guard let self else { return "" }
                    return "\(self.settings.hiddenCalendarIDs.sorted())|\(self.settings.calendarRange.rawValue)|\(self.settings.calendarShowsAllDay)"
                }) { [weak self] _ in
                    guard let self, self.isActive else { return }
                    self.refresh()
                }
            }
            syncNow()
        } else {
            removeObservers()
            tickTask?.cancel()
            syncTask?.cancel()
            permissionWatchTask?.cancel()
            events = []
        }
    }

    private func observeStore() {
        let change = NotificationCenter.default.addObserver(forName: .EKEventStoreChanged, object: store, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        observers.append(change)
    }

    private func removeObservers() {
        for observer in observers {
            NotificationCenter.default.removeObserver(observer)
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
        observers.removeAll()
    }

    func requestAccess() async {
        do {
            _ = try await store.requestFullAccessToEvents()
        } catch {
            // Falls through to the status check below.
        }
        updateAccess()
        if access == .granted {
            settings.calendarWasConnected = true
            // A store created before authorization can keep returning an empty result set;
            // start from a fresh one now that access exists.
            store = EKEventStore()
            if isActive {
                removeObservers()
                observeStore()
            }
        }
        syncNow()
    }

    private func recheckAccess() {
        guard access != .granted else { return }
        updateAccess()
        guard access == .granted else { return }
        settings.calendarWasConnected = true
        store = EKEventStore() // a store created before access was granted can stay empty
        if isActive {
            removeObservers()
            observeStore()
        }
        syncNow()
    }

    /// Asks remote accounts to fetch changes, then re-reads. Results arriving later trigger
    /// `EKEventStoreChanged`, which re-reads again.
    func syncNow() {
        updateAccess()
        if access == .granted { store.refreshSourcesIfNecessary() }
        refresh()
    }

    func refresh() {
        updateAccess()
        guard access == .granted else {
            events = []
            calendars = []
            return
        }

        let eventCalendars = store.calendars(for: .event)
        calendars = eventCalendars
            .map { CalendarInfo(id: $0.calendarIdentifier, title: $0.title, sourceTitle: $0.source?.title ?? "Other", color: Self.rgb($0.color)) }
            .sorted { ($0.sourceTitle, $0.title) < ($1.sourceTitle, $1.title) }

        let hidden = settings.hiddenCalendarIDs
        let selected = eventCalendars.filter { !hidden.contains($0.calendarIdentifier) }
        guard !selected.isEmpty else {
            events = []
            lastRefreshed = Date()
            return
        }

        let now = Date()
        // Start a day back so long ongoing events (and today's all-day ones) are included.
        let predicate = store.predicateForEvents(
            withStart: now.addingTimeInterval(-24 * 3600),
            end: now.addingTimeInterval(settings.calendarRange.interval),
            calendars: selected
        )
        let showsAllDay = settings.calendarShowsAllDay
        events = store.events(matching: predicate)
            .filter { event in
                event.endDate > now
                    && event.status != .canceled
                    && (showsAllDay || !event.isAllDay)
                    && event.attendees?.first(where: \.isCurrentUser)?.participantStatus != .declined
            }
            .sorted { $0.startDate < $1.startDate }
            .prefix(Self.maximumEvents)
            .map(Self.makeEvent)
        lastRefreshed = now
    }

    func setCalendar(_ id: String, visible: Bool) {
        if visible { settings.hiddenCalendarIDs.remove(id) } else { settings.hiddenCalendarIDs.insert(id) }
    }

    func isVisible(_ id: String) -> Bool { !settings.hiddenCalendarIDs.contains(id) }

    private func updateAccess() {
        access = switch EKEventStore.authorizationStatus(for: .event) {
        case .fullAccess: .granted
        case .notDetermined: .notDetermined
        default: .denied
        }
    }

    private static func rgb(_ color: NSColor?) -> ArtworkPalette.RGB? {
        color?.usingColorSpace(.sRGB).map {
            ArtworkPalette.RGB(red: Double($0.redComponent), green: Double($0.greenComponent), blue: Double($0.blueComponent))
        }
    }

    private static func makeEvent(_ event: EKEvent) -> UpcomingEvent {
        UpcomingEvent(
            id: (event.eventIdentifier ?? UUID().uuidString) + "@\(event.startDate.timeIntervalSince1970)",
            title: event.title?.isEmpty == false ? event.title! : "Untitled event",
            start: event.startDate,
            end: event.endDate,
            isAllDay: event.isAllDay,
            calendarColor: rgb(event.calendar?.color),
            calendarTitle: event.calendar?.title,
            location: event.location,
            meetingLink: MeetingLinkParser.firstLink(in: [event.url?.absoluteString, event.location, event.notes])
        )
    }

    func join(_ event: UpcomingEvent) {
        if let url = event.meetingLink?.url { NSWorkspace.shared.open(url) }
    }

    func openPrivacySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars") {
            NSWorkspace.shared.open(url)
        }
    }
}
