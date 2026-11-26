import SwiftUI

struct ModulesSettingsPane: View {
    @Environment(SettingsStore.self) private var settings

    var body: some View {
        @Bindable var settings = settings

        ScrollView {
        VStack(alignment: .leading, spacing: 10) {
            Text("Choose which modules appear in the notch, and drag to set their tab order.")
                .foregroundStyle(.secondary)

            List {
                ForEach($settings.modules) { $configuration in
                    ModuleRow(configuration: $configuration)
                }
                .onMove { source, destination in
                    settings.modules.move(fromOffsets: source, toOffset: destination)
                }
            }
            .listStyle(.inset(alternatesRowBackgrounds: true))
            .frame(height: 250)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(.separator)
            }

            HStack {
                Text("\(settings.enabledModules.count) of \(settings.modules.count) enabled")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Restore Defaults") { settings.resetModules() }
            }

            CalendarModuleSettings()
            SystemMonitorSettings()
            LiveActivitiesSettings()
            PomodoroSettings()
            ClipboardSettings()
        }
        .padding(20)
        }
    }
}

/// Which Live Activities run.
private struct LiveActivitiesSettings: View {
    @Environment(SettingsStore.self) private var settings
    @Environment(LiveActivitiesStore.self) private var live

    var body: some View {
        @Bindable var settings = settings
        GroupBox {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 18) {
                    Toggle("Battery", isOn: $settings.liveBatteryEnabled)
                        .disabled(!live.hasBattery)
                        .help(live.hasBattery ? "Charging, unplugged, and low-battery pills" : "This Mac has no battery")
                    Toggle("Bluetooth devices", isOn: $settings.liveBluetoothEnabled)
                    Toggle("Downloads", isOn: $settings.liveDownloadsEnabled)
                }
                Text("Pills appear beside the notch for a few seconds. Bluetooth and Downloads ask for permission the first time they run.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(6)
        } label: {
            Label("Live Activities", systemImage: "bolt.fill")
        }
    }
}

/// Pomodoro durations and behavior.
private struct PomodoroSettings: View {
    @Environment(SettingsStore.self) private var settings

    var body: some View {
        @Bindable var settings = settings
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 14) {
                    Stepper("Focus \(settings.pomodoroFocusMinutes) min", value: $settings.pomodoroFocusMinutes,
                            in: SettingsStore.pomodoroFocusRange, step: 5)
                    Stepper("Break \(settings.pomodoroShortBreakMinutes) min", value: $settings.pomodoroShortBreakMinutes,
                            in: SettingsStore.pomodoroShortBreakRange)
                    Stepper("Long break \(settings.pomodoroLongBreakMinutes) min", value: $settings.pomodoroLongBreakMinutes,
                            in: SettingsStore.pomodoroLongBreakRange, step: 5)
                }
                HStack(spacing: 14) {
                    Stepper("Long break every \(settings.pomodoroSessionsBeforeLongBreak) sessions",
                            value: $settings.pomodoroSessionsBeforeLongBreak, in: SettingsStore.pomodoroSessionsRange)
                    Toggle("Chime", isOn: $settings.pomodoroSoundEnabled)
                }
                HStack(spacing: 14) {
                    Toggle("Start breaks automatically", isOn: $settings.pomodoroAutoStartBreaks)
                    Toggle("Start focus automatically", isOn: $settings.pomodoroAutoStartFocus)
                }
            }
            .padding(6)
        } label: {
            Label("Pomodoro", systemImage: "timer")
        }
    }
}

/// Clipboard history size and content.
private struct ClipboardSettings: View {
    @Environment(SettingsStore.self) private var settings
    @Environment(ClipboardStore.self) private var clipboard

    var body: some View {
        @Bindable var settings = settings
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 14) {
                    Picker("Keep the last", selection: $settings.clipboardHistoryLimit) {
                        ForEach(SettingsStore.clipboardLimits, id: \.self) { Text("\($0) clips").tag($0) }
                    }
                    .fixedSize()
                    Toggle("Include images", isOn: $settings.clipboardCapturesImages)
                    Spacer()
                    Button("Clear History") { clipboard.clear() }
                }
                Text(accessSummary)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if clipboard.access != .allowed {
                    Button("Open Privacy & Security…") { clipboard.openPrivacySettings() }
                }
            }
            .padding(6)
        } label: {
            Label("Clipboard", systemImage: "doc.on.clipboard")
        }
    }

    private var accessSummary: String {
        let base = "Kept in memory only and cleared when NotchDeck quits. Password-manager copies are skipped."
        return switch clipboard.access {
        case .allowed: base
        case .asks: base + " To record clips automatically, set NotchDeck to Allow under Privacy & Security → Paste from Other Apps."
        case .denied: base + " NotchDeck is set to Deny under Privacy & Security → Paste from Other Apps."
        }
    }
}

/// System monitor options: sampling rate and overview style.
private struct SystemMonitorSettings: View {
    @Environment(SettingsStore.self) private var settings

    var body: some View {
        @Bindable var settings = settings
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Picker("Refresh every", selection: $settings.systemMonitorInterval) {
                        ForEach(SettingsStore.systemMonitorIntervals, id: \.self) { seconds in
                            Text(SystemMonitorModuleView.intervalLabel(seconds)).tag(seconds)
                        }
                    }
                    .pickerStyle(.segmented)
                    .fixedSize()
                    Spacer()
                    Text("Samples only while the System tab is open.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                HStack(alignment: .firstTextBaseline) {
                    Picker("CPU / GPU / memory style", selection: $settings.systemOverviewStyle) {
                        ForEach(SystemOverviewStyle.allCases) { Text($0.displayName).tag($0) }
                    }
                    .fixedSize()
                    Text(settings.systemOverviewStyle.summary)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
            .padding(6)
        } label: {
            Label("System Monitor", systemImage: "cpu")
        }
    }
}

/// Calendar module options: range, all-day events, and which calendars to include.
private struct CalendarModuleSettings: View {
    @Environment(SettingsStore.self) private var settings
    @Environment(CalendarStore.self) private var calendar
    @State private var choosingCalendars = false

    var body: some View {
        @Bindable var settings = settings

        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Picker("Show events for the", selection: $settings.calendarRange) {
                        ForEach(CalendarRange.allCases) { Text($0.displayName.lowercased()).tag($0) }
                    }
                    .fixedSize()
                    Spacer()
                    Toggle("Include all-day events", isOn: $settings.calendarShowsAllDay)
                }
                HStack {
                    Text(calendarSummary)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Spacer()
                    if calendar.access == .granted {
                        Button("Choose Calendars…") { choosingCalendars = true }
                    } else {
                        Button("Connect Calendar…") { Task { await calendar.requestAccess() } }
                    }
                }
            }
            .padding(6)
        } label: {
            Label("Calendar", systemImage: "calendar")
        }
        .onAppear { calendar.refresh() }
        .sheet(isPresented: $choosingCalendars) {
            CalendarSelectionSheet()
        }
    }

    private var calendarSummary: String {
        switch calendar.access {
        case .granted:
            "Showing \(calendar.visibleCalendarCount) of \(calendar.calendars.count) calendars. Refreshes every 5 minutes and on wake."
        case .denied:
            "Calendar access is off in System Settings → Privacy & Security → Calendars."
        case .notDetermined:
            "Not connected yet."
        }
    }
}

/// Per-calendar on/off, grouped by account (iCloud, Google, Exchange, …).
private struct CalendarSelectionSheet: View {
    @Environment(CalendarStore.self) private var calendar
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let groups = Dictionary(grouping: calendar.calendars, by: \.sourceTitle)
        VStack(alignment: .leading, spacing: 12) {
            Text("Calendars in the Notch").font(.headline)
            Text("Turned-off calendars are hidden from the event list and the collapsed meeting banner.")
                .font(.callout)
                .foregroundStyle(.secondary)

            List {
                ForEach(groups.keys.sorted(), id: \.self) { source in
                    Section(source) {
                        ForEach(groups[source] ?? []) { info in
                            Toggle(isOn: Binding(
                                get: { calendar.isVisible(info.id) },
                                set: { calendar.setCalendar(info.id, visible: $0) }
                            )) {
                                HStack(spacing: 8) {
                                    Circle()
                                        .fill(info.color?.color ?? .accentColor)
                                        .frame(width: 10, height: 10)
                                    Text(info.title)
                                }
                            }
                        }
                    }
                }
            }
            .frame(minHeight: 260)

            HStack {
                Button("Show All") {
                    calendar.calendars.forEach { calendar.setCalendar($0.id, visible: true) }
                }
                Button("Hide All") {
                    calendar.calendars.forEach { calendar.setCalendar($0.id, visible: false) }
                }
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 420, height: 440)
    }
}

private struct ModuleRow: View {
    @Binding var configuration: ModuleConfiguration

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "line.3.horizontal")
                .foregroundStyle(.tertiary)
            Image(systemName: configuration.module.symbolName)
                .frame(width: 22)
                .foregroundStyle(configuration.isEnabled ? Color.accentColor : .secondary)
            Text(configuration.module.displayName)
            Spacer()
            if !configuration.module.isAvailable {
                Text("Phase \(configuration.module.phase)")
                    .font(.caption.weight(.medium))
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .foregroundStyle(.secondary)
                    .background(.quaternary, in: Capsule())
                    .help("Ships in roadmap phase \(configuration.module.phase)")
            }
            Toggle("", isOn: $configuration.isEnabled)
                .toggleStyle(.switch)
                .controlSize(.small)
                .labelsHidden()
                .accessibilityLabel("Enable \(configuration.module.displayName)")
        }
        .padding(.vertical, 3)
    }
}
