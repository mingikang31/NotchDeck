import AppKit
import Foundation
import Testing
@testable import NotchDeck

/// Drives real pasteboards through the drop handler: the same NSPasteboard API the system
/// drag pasteboard uses when a file from Finder, an image from a browser or text is dropped.
struct FileTrayDropTests {
    private let root = FileManager.default.temporaryDirectory
        .appending(path: "NotchDeckDropTests-\(UUID().uuidString)", directoryHint: .isDirectory)

    private func store() -> FileTrayStore {
        FileTrayStore(directory: root.appending(path: "support", directoryHint: .isDirectory))
    }

    private func pasteboard() -> NSPasteboard {
        let board = NSPasteboard(name: NSPasteboard.Name("NotchDeckTests-\(UUID().uuidString)"))
        board.clearContents()
        return board
    }

    @Test func droppedFilesAreAddedImmediately() throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let pdf = root.appending(path: "Quarterly Report.pdf")
        let png = root.appending(path: "Screenshot.png")
        try Data("%PDF-1.4".utf8).write(to: pdf)
        try Data([0x89, 0x50]).write(to: png)
        let board = pasteboard()
        board.writeObjects([pdf as NSURL, png as NSURL])
        defer { board.releaseGlobally() }

        #expect(FileTrayStore.canAccept(board))
        let tray = store()
        #expect(tray.handleDrop(pasteboard: board))
        #expect(tray.items.map(\.displayName) == ["Quarterly Report.pdf", "Screenshot.png"])
        #expect(tray.items.allSatisfy { !$0.isStaged })
    }

    @Test func droppedTextIsStaged() {
        let board = pasteboard()
        board.setString("Meeting notes", forType: .string)
        defer { board.releaseGlobally() }

        let tray = store()
        #expect(tray.handleDrop(pasteboard: board))
        #expect(tray.items.first?.isStaged == true)
        #expect(tray.items.first?.displayName.hasSuffix(".txt") == true)
    }

    @Test func droppedWebLinkIsStagedAsText() throws {
        let board = pasteboard()
        board.writeObjects([try #require(URL(string: "https://example.com/article")) as NSURL])
        defer { board.releaseGlobally() }

        let tray = store()
        #expect(tray.handleDrop(pasteboard: board))
        let item = try #require(tray.items.first)
        let url = try #require(tray.url(for: item))
        #expect(try String(contentsOf: url, encoding: .utf8) == "https://example.com/article")
    }

    @Test func droppedTIFFImageIsStoredAsPNG() throws {
        let image = NSImage(size: NSSize(width: 4, height: 4))
        image.lockFocus()
        NSColor.red.setFill()
        NSRect(x: 0, y: 0, width: 4, height: 4).fill()
        image.unlockFocus()
        let board = pasteboard()
        board.setData(image.tiffRepresentation, forType: .tiff)
        defer { board.releaseGlobally() }

        let tray = store()
        #expect(tray.handleDrop(pasteboard: board))
        #expect(tray.items.first?.displayName.hasSuffix(".png") == true)
    }

    @Test func unsupportedContentIsRejected() {
        let board = pasteboard()
        board.setData(Data([1, 2, 3]), forType: NSPasteboard.PasteboardType("com.example.private"))
        defer { board.releaseGlobally() }

        #expect(!FileTrayStore.canAccept(board))
        #expect(store().handleDrop(pasteboard: board) == false)
    }

    @Test func permissionsArePerSessionByDefault() {
        let name = "NotchDeckTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        #expect(SettingsStore(defaults: defaults).permissionsPerSession)
        defaults.removePersistentDomain(forName: name)
    }
}

struct CalendarGroupingTests {
    private let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        return calendar
    }()

    /// Wed Nov 25 2026, 10:00 in Los Angeles.
    private var now: Date {
        calendar.date(from: DateComponents(year: 2026, month: 11, day: 25, hour: 10))!
    }

    private func event(_ id: String, dayOffset: Int, hour: Int, allDay: Bool = false, hours: Int = 1) -> UpcomingEvent {
        let start = calendar.date(byAdding: .day, value: dayOffset, to: calendar.date(bySettingHour: allDay ? 0 : hour, minute: 0, second: 0, of: now)!)!
        return UpcomingEvent(id: id, title: id, start: start, end: start.addingTimeInterval(Double(allDay ? 24 : hours) * 3600), isAllDay: allDay)
    }

    @Test func groupsByDayWithFriendlyTitles() {
        let days = CalendarStore.groupByDay([
            event("standup", dayOffset: 0, hour: 11),
            event("offsite", dayOffset: 0, hour: 0, allDay: true),
            event("review", dayOffset: 1, hour: 9),
            event("planning", dayOffset: 3, hour: 14),
        ], now: now, calendar: calendar)

        #expect(days.map(\.title).prefix(2) == ["Today", "Tomorrow"])
        #expect(days.count == 3)
        #expect(days[0].events.map(\.id) == ["offsite", "standup"]) // all-day first
    }

    @Test func ongoingEventFromYesterdayListsUnderToday() {
        let overnight = event("deploy", dayOffset: -1, hour: 22, hours: 14)
        let days = CalendarStore.groupByDay([overnight], now: now, calendar: calendar)
        #expect(days.first?.title == "Today")
    }

    @Test func bannerSkipsAllDayEvents() {
        let events = [event("holiday", dayOffset: 0, hour: 0, allDay: true), event("sync", dayOffset: 0, hour: 13)]
        #expect(CalendarStore.nextTimedEvent(in: events, at: now)?.id == "sync")
        #expect(events[0].countdown(from: now) == "All day")
    }

    @Test func calendarPreferencesPersist() {
        let name = "NotchDeckTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        let store = SettingsStore(defaults: defaults)
        #expect(store.calendarRange == .next3Days)
        #expect(store.calendarShowsAllDay)
        store.hiddenCalendarIDs = ["cal-A", "cal-B"]
        store.calendarRange = .next7Days
        store.calendarShowsAllDay = false

        let reloaded = SettingsStore(defaults: defaults)
        #expect(reloaded.hiddenCalendarIDs == ["cal-A", "cal-B"])
        #expect(reloaded.calendarRange == .next7Days)
        #expect(!reloaded.calendarShowsAllDay)
        defaults.removePersistentDomain(forName: name)
    }
}
