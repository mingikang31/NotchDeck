import SwiftUI

/// Expanded Calendar: upcoming events with one-click Join.
struct CalendarModuleView: View {
    let tokens: ThemeTokens

    @Environment(CalendarStore.self) private var calendar
    @Environment(SettingsStore.self) private var settings
    @Environment(\.settingsOpener) private var settingsOpener

    var body: some View {
        switch calendar.access {
        case .notDetermined:
            prompt(
                title: "See your next meeting here",
                detail: "Shows upcoming events and a one-click Join button for Zoom, Meet, Teams and Webex.",
                button: "Connect Calendar"
            ) {
                Task { await calendar.requestAccess() }
            }
        case .denied:
            prompt(
                title: "Calendar access is off",
                detail: "Allow NotchDeck in System Settings → Privacy & Security → Calendars.",
                button: "Open Privacy Settings"
            ) {
                calendar.openPrivacySettings()
            }
        case .granted:
            VStack(alignment: .leading, spacing: 6) {
                toolbar
                if calendar.events.isEmpty {
                    HStack(spacing: 14) {
                        icon("calendar.badge.checkmark")
                        VStack(alignment: .leading, spacing: 3) {
                            Text(calendar.visibleCalendarCount == 0 ? "No calendars selected" : "You're free")
                                .font(.system(size: 14, weight: .semibold))
                            Text(calendar.visibleCalendarCount == 0
                                 ? "Choose calendars in Settings → Modules."
                                 : "Nothing in the \(settings.calendarRange.displayName.lowercased()).")
                                .font(.system(size: 11))
                                .foregroundStyle(tokens.secondaryText)
                        }
                        Spacer()
                    }
                } else {
                    TimelineView(.periodic(from: .now, by: 30)) { context in
                        let isScrollable = calendar.events.count > 3
                        ScrollView(.vertical) {
                            LazyVStack(alignment: .leading, spacing: 5) {
                                ForEach(calendar.eventDays(now: context.date)) { day in
                                    Section {
                                        ForEach(day.events) { event in
                                            EventRow(event: event, now: context.date, tokens: tokens)
                                        }
                                    } header: {
                                        Text(day.title.uppercased())
                                            .font(.system(size: 9, weight: .bold))
                                            .foregroundStyle(tokens.secondaryText)
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                            .padding(.top, 2)
                                    }
                                }
                            }
                            .padding(.trailing, 8)
                            // Room to scroll the last event fully clear of the bottom fade.
                            .padding(.bottom, isScrollable ? 18 : 0)
                        }
                        .scrollIndicators(.visible)
                        // Fade the bottom edge when there's more below, so it reads as scrollable.
                        .mask {
                            LinearGradient(
                                stops: [
                                    .init(color: .black, location: 0),
                                    .init(color: .black, location: isScrollable ? 0.78 : 1),
                                    .init(color: .black.opacity(isScrollable ? 0 : 1), location: 1),
                                ],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        }
                    }
                }
            }
        }
    }

    private var toolbar: some View {
        HStack(spacing: 6) {
            Text(summary)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(tokens.secondaryText)
            Spacer()
            smallButton("arrow.clockwise", help: "Refresh calendars") { calendar.syncNow() }
            smallButton("slider.horizontal.3", help: "Choose calendars…") { settingsOpener.open(.modules) }
        }
    }

    private var summary: String {
        let count = calendar.events.count
        let scrollHint = count > 3 ? " · scroll for more" : ""
        let base = "\(count) event\(count == 1 ? "" : "s") · \(settings.calendarRange.displayName.lowercased())" + scrollHint
        guard let refreshed = calendar.lastRefreshed else { return base }
        return base + " · updated " + refreshed.formatted(date: .omitted, time: .shortened)
    }

    private func smallButton(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 9.5, weight: .bold))
                .frame(width: 20, height: 17)
                .background(tokens.controlFill, in: Capsule())
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .foregroundStyle(tokens.secondaryText)
        .help(help)
    }

    private func prompt(title: String, detail: String, button: String, action: @escaping () -> Void) -> some View {
        HStack(spacing: 14) {
            icon("calendar")
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.system(size: 14, weight: .semibold))
                Text(detail).font(.system(size: 11)).foregroundStyle(tokens.secondaryText)
                Button(button, action: action).controlSize(.small)
            }
            Spacer()
        }
    }

    private func icon(_ name: String) -> some View {
        Image(systemName: name)
            .font(.system(size: 22, weight: .semibold))
            .frame(width: 56, height: 56)
            .background(tokens.controlFill, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

private struct EventRow: View {
    let event: UpcomingEvent
    let now: Date
    let tokens: ThemeTokens

    @Environment(CalendarStore.self) private var calendar

    var body: some View {
        HStack(spacing: 10) {
            Capsule()
                .fill(event.calendarColor?.color ?? .accentColor)
                .frame(width: 3, height: 24)
            VStack(alignment: .leading, spacing: 1) {
                Text(event.title)
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)
                Text(timeRange)
                    .font(.system(size: 10.5).monospacedDigit())
                    .foregroundStyle(tokens.secondaryText)
            }
            Spacer(minLength: 8)
            if !event.isAllDay {
                Text(event.countdown(from: now))
                    .font(.system(size: 10.5, weight: .semibold).monospacedDigit())
                    .foregroundStyle(event.isOngoing(at: now) ? Color.green : tokens.secondaryText)
            }
            if let link = event.meetingLink {
                Button {
                    calendar.join(event)
                } label: {
                    Label("Join", systemImage: "video.fill")
                        .font(.system(size: 10.5, weight: .semibold))
                        .padding(.horizontal, 9)
                        .padding(.vertical, 4)
                        .background(Color.green.opacity(0.85), in: Capsule())
                        .foregroundStyle(.white)
                }
                .buttonStyle(.plain)
                .help("Join on \(link.provider.displayName)")
            }
        }
    }

    private var timeRange: String {
        let calendarName = event.calendarTitle.map { " · \($0)" } ?? ""
        if event.isAllDay { return "All day" + calendarName }
        return event.start.formatted(date: .omitted, time: .shortened) + " – "
            + event.end.formatted(date: .omitted, time: .shortened) + calendarName
    }
}
