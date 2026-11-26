import AppKit
import Foundation
import Testing
@testable import NotchDeck

// MARK: Live Activities

struct BatteryToastTests {
    private func status(_ percent: Int, plugged: Bool, charging: Bool = false, minutesLeft: Int? = nil) -> BatteryStatus {
        BatteryStatus(percent: percent, isPluggedIn: plugged, isCharging: charging, isCharged: percent >= 100,
                      minutesToEmpty: minutesLeft, minutesToFull: nil)
    }

    @Test func plugAndUnplugFlashAPill() {
        #expect(BatteryMonitor.toast(from: status(64, plugged: false), to: status(64, plugged: true, charging: true)) == .charging(percent: 64))
        #expect(BatteryMonitor.toast(from: status(100, plugged: false), to: status(100, plugged: true)) == .charged)
        #expect(BatteryMonitor.toast(from: status(64, plugged: true), to: status(64, plugged: false, minutesLeft: 300))
                == .onBattery(percent: 64, minutesLeft: 300))
    }

    @Test func lowBatteryFiresOncePerThreshold() {
        #expect(BatteryMonitor.toast(from: status(21, plugged: false), to: status(20, plugged: false)) == .lowBattery(percent: 20))
        #expect(BatteryMonitor.toast(from: status(20, plugged: false), to: status(19, plugged: false)) == nil)
        #expect(BatteryMonitor.toast(from: status(11, plugged: false), to: status(10, plugged: false)) == .lowBattery(percent: 10))
        #expect(BatteryMonitor.toast(from: status(6, plugged: false), to: status(5, plugged: false)) == .lowBattery(percent: 5))
        // Charging through a threshold is not a warning.
        #expect(BatteryMonitor.toast(from: status(21, plugged: true, charging: true), to: status(20, plugged: true, charging: true)) == nil)
    }

    @Test func fullChargeWhilePluggedIn() {
        #expect(BatteryMonitor.toast(from: status(99, plugged: true, charging: true), to: status(100, plugged: true)) == .charged)
        #expect(BatteryMonitor.toast(from: nil, to: status(50, plugged: true)) == nil) // first reading is silent
    }

    @Test func descriptions() {
        var s = status(40, plugged: false, minutesLeft: 272)
        #expect(s.stateDescription == "On battery")
        #expect(s.timeDescription == "4h 32m left")
        s = BatteryStatus(percent: 80, isPluggedIn: true, isCharging: true, isCharged: false, minutesToEmpty: nil, minutesToFull: 45)
        #expect(s.stateDescription == "Charging")
        #expect(s.timeDescription == "45m to full")
        s.isCharging = false
        #expect(s.stateDescription == "Plugged in, not charging")
    }

    /// Reads this Mac's real battery (skips on desktops).
    @Test func liveReadingIsSane() throws {
        guard let status = BatteryMonitor.read() else { return }
        #expect((0...100).contains(status.percent))
        if let watts = status.batteryWatts { #expect(abs(watts) < 300) }
        if let health = status.healthPercent { #expect((30...100).contains(health)) }
    }
}

struct BluetoothInfoTests {
    @Test func symbolsByNameAndClass() {
        #expect(BluetoothDeviceInfo.symbol(name: "Mingi’s AirPods Pro", major: 0x04, minor: 0) == "airpodspro")
        #expect(BluetoothDeviceInfo.symbol(name: "AirPods Max", major: 0x04, minor: 0) == "airpodsmax")
        #expect(BluetoothDeviceInfo.symbol(name: "Magic Keyboard", major: 0x05, minor: 0x10) == "keyboard")
        #expect(BluetoothDeviceInfo.symbol(name: "WH-1000XM5", major: 0x04, minor: 0) == "headphones")
        #expect(BluetoothDeviceInfo.symbol(name: "Thing", major: 0x1F, minor: 0) == "dot.radiowaves.left.and.right")
    }

    @Test func headlineBatteryIgnoresTheCase() {
        let buds = BluetoothDeviceInfo(id: "1", name: "AirPods", symbol: "airpods",
                                       batteries: [.init(label: "L", percent: 80), .init(label: "R", percent: 72), .init(label: "Case", percent: 10)])
        #expect(buds.headlineBattery == 72)
        let caseOnly = BluetoothDeviceInfo(id: "2", name: "AirPods", symbol: "airpods", batteries: [.init(label: "Case", percent: 55)])
        #expect(caseOnly.headlineBattery == 55)
    }
}

struct DownloadsWatcherTests {
    @Test func temporaryNamesAreIgnored() {
        #expect(DownloadsWatcher.isFinishedDownload("report.pdf"))
        #expect(DownloadsWatcher.isFinishedDownload("Archive"))
        #expect(!DownloadsWatcher.isFinishedDownload("report.pdf.crdownload"))
        #expect(!DownloadsWatcher.isFinishedDownload("movie.mp4.download"))
        #expect(!DownloadsWatcher.isFinishedDownload("big.iso.part"))
        #expect(!DownloadsWatcher.isFinishedDownload(".DS_Store"))
        #expect(!DownloadsWatcher.isFinishedDownload("Unconfirmed 123456.crdownload"))
    }

    /// A browser-style download (temp name, then rename) is reported once, under its final name.
    @Test func reportsRenamedDownload() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "NDDownloads-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try Data("old".utf8).write(to: directory.appending(path: "existing.txt"))

        let watcher = DownloadsWatcher(directory: directory)
        var reported: [String] = []
        watcher.onNewFile = { reported.append($0.name) }
        let seed = await watcher.start()
        #expect(seed.map(\.name) == ["existing.txt"])

        let temp = directory.appending(path: "photo.jpg.crdownload")
        try Data(repeating: 7, count: 4096).write(to: temp)
        try await Task.sleep(for: .milliseconds(300))
        try FileManager.default.moveItem(at: temp, to: directory.appending(path: "photo.jpg"))

        for _ in 0..<40 where reported.isEmpty { try await Task.sleep(for: .milliseconds(100)) }
        watcher.stop()
        #expect(reported == ["photo.jpg"])
    }
}

struct ToastCenterTests {
    @Test func toastDismissesItself() async throws {
        let center = NotchToastCenter()
        center.show(LiveToast(.charged, duration: 0.1))
        #expect(center.current?.kind == .charged)
        for _ in 0..<40 where center.current != nil { try await Task.sleep(for: .milliseconds(50)) }
        #expect(center.current == nil)
    }

    @Test func newerToastReplacesAndOutlivesOlderTimer() async throws {
        let center = NotchToastCenter()
        center.show(LiveToast(.charged, duration: 0.1))
        center.show(LiveToast(.download(name: "a.zip"), duration: 5))
        try await Task.sleep(for: .milliseconds(300))
        #expect(center.current?.kind == .download(name: "a.zip"))
        #expect(LiveToast(.download(name: "a")).module == .liveActivities)
        #expect(LiveToast(.pomodoro(title: "", detail: "", isBreak: true)).module == .pomodoro)
    }
}

struct Phase6PriorityAndLayoutTests {
    @Test func pomodoroSitsBetweenUrgentEventsAndMedia() {
        #expect(LiveActivityCoordinator.resolve(isMediaPlaying: true, event: nil, isPomodoroActive: true) == .pomodoro)
        #expect(LiveActivityCoordinator.resolve(isMediaPlaying: true, event: ("e", 5 * 60, false), isPomodoroActive: true) == .upcomingEvent(id: "e"))
        #expect(LiveActivityCoordinator.resolve(isMediaPlaying: false, event: ("e", 40 * 60, false), isPomodoroActive: true) == .pomodoro)
    }

    @Test func layouts() {
        #expect(ExpandedLayout.forModule(.todos, hasPendingApproval: false) == .tall)
        #expect(ExpandedLayout.forModule(.clipboard, hasPendingApproval: false) == .tall)
        #expect(ExpandedLayout.forModule(.mirror, hasPendingApproval: false) == .tall)
        #expect(ExpandedLayout.forModule(.pomodoro, hasPendingApproval: false) == .standard)
        #expect(ExpandedLayout.forModule(.liveActivities, hasPendingApproval: false, fittedHeight: 240) == .fitted(240))
        let allAvailable = NotchModule.allCases.allSatisfy { $0.isAvailable }
        #expect(allAvailable)
    }
}

// MARK: Pomodoro

struct PomodoroLogicTests {
    private let plan = PomodoroPlan(focus: 25 * 60, shortBreak: 5 * 60, longBreak: 15 * 60, sessionsBeforeLongBreak: 2)
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func startPauseResume() {
        var state = PomodoroLogic.start(PomodoroState(), plan: plan, at: t0)
        #expect(state.isRunning)
        #expect(PomodoroLogic.remaining(state, plan: plan, at: t0.addingTimeInterval(60)) == 24 * 60)
        state = PomodoroLogic.pause(state, at: t0.addingTimeInterval(600))
        #expect(state.isPaused)
        #expect(PomodoroLogic.remaining(state, plan: plan, at: t0.addingTimeInterval(9999)) == 15 * 60) // frozen while paused
        state = PomodoroLogic.start(state, plan: plan, at: t0.addingTimeInterval(1000))
        #expect(state.endDate == t0.addingTimeInterval(1000 + 15 * 60))
    }

    @Test func cycleEndsInALongBreak() {
        var state = PomodoroState(todayStamp: PomodoroState.dayStamp(t0))
        state = PomodoroLogic.advance(state, plan: plan, counted: true, at: t0)
        #expect(state.phase == .shortBreak)
        state = PomodoroLogic.advance(state, plan: plan, counted: true, at: t0)
        #expect(state.phase == .focus)
        state = PomodoroLogic.advance(state, plan: plan, counted: true, at: t0)
        #expect(state.phase == .longBreak)
        #expect(state.completedToday == 2)
        state = PomodoroLogic.advance(state, plan: plan, counted: true, at: t0)
        #expect(state.phase == .focus)
        #expect(state.completedInCycle == 0)
        #expect(state.isIdle)
    }

    @Test func skippedFocusDoesNotCountAndNewDayResets() {
        var state = PomodoroState(completedToday: 5, todayStamp: "2020-01-01")
        state = PomodoroLogic.advance(state, plan: plan, counted: false, at: t0)
        #expect(state.phase == .shortBreak)
        #expect(state.completedInCycle == 0)
        #expect(state.completedToday == 0) // a new day started
    }

    @Test func clockFormatting() {
        #expect(PomodoroLogic.clock(25 * 60) == "25:00")
        #expect(PomodoroLogic.clock(59.2) == "1:00")
        #expect(PomodoroLogic.clock(3725) == "1:02:05")
    }

    @Test func runningTimerSurvivesRelaunch() {
        let name = "NotchDeckPomodoro.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let settings = SettingsStore(defaults: defaults)
        let timer = PomodoroTimer(settings: settings, toasts: NotchToastCenter(), defaults: defaults)
        timer.start()
        let end = timer.state.endDate
        #expect(end != nil)
        let relaunched = PomodoroTimer(settings: settings, toasts: NotchToastCenter(), defaults: defaults)
        #expect(relaunched.state.endDate == end)
        relaunched.reset()
        #expect(relaunched.state.isIdle)
    }

    @Test func settingsDefaultsAndClamping() {
        let name = "NotchDeckPomodoroSettings.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let settings = SettingsStore(defaults: defaults)
        #expect(settings.pomodoroFocusMinutes == 25)
        #expect(settings.pomodoroShortBreakMinutes == 5)
        #expect(settings.pomodoroLongBreakMinutes == 15)
        #expect(settings.pomodoroSessionsBeforeLongBreak == 4)
        settings.pomodoroFocusMinutes = 500
        #expect(settings.pomodoroFocusMinutes == 90)
        #expect(SettingsStore(defaults: defaults).pomodoroFocusMinutes == 90)
        settings.clipboardHistoryLimit = 30
        #expect(settings.clipboardHistoryLimit == 25)
        #expect(settings.liveBluetoothEnabled && settings.liveDownloadsEnabled && settings.liveBatteryEnabled)
    }
}

// MARK: To-Dos

struct TodoStoreTests {
    private func makeDirectory() -> URL {
        FileManager.default.temporaryDirectory.appending(path: "NDTodos-\(UUID().uuidString)")
    }

    @Test func addToggleRenameDeleteAndPersist() throws {
        let directory = makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = TodoStore(directory: directory)
        store.add("  Buy milk  ")
        store.add("   ")              // ignored
        store.add("Ship Phase 6")
        store.add("Call Sam")
        #expect(store.items.map(\.title) == ["Buy milk", "Ship Phase 6", "Call Sam"])

        let milk = store.items[0].id
        store.toggle(milk)
        #expect(store.sortedItems.map(\.title) == ["Ship Phase 6", "Call Sam", "Buy milk"]) // done sink to the bottom
        #expect(store.openCount == 2 && store.doneCount == 1)

        store.rename(store.items[1].id, to: "Ship Phase 6 🎉")
        store.rename(store.items[2].id, to: "")  // empty title deletes
        #expect(store.items.count == 2)

        let reloaded = TodoStore(directory: directory)
        #expect(reloaded.items == store.items)

        reloaded.clearDone()
        #expect(reloaded.items.map(\.title) == ["Ship Phase 6 🎉"])
    }

    @Test func unreadableFileIsBackedUpNotOverwritten() throws {
        let directory = makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: directory.appending(path: "todos.json"))
        let store = TodoStore(directory: directory)
        #expect(store.items.isEmpty)
        #expect(store.lastError != nil)
        #expect(FileManager.default.fileExists(atPath: directory.appending(path: "todos.unreadable.json").path))
    }
}

// MARK: Clipboard

struct ClipboardTests {
    @Test func insertingDeduplicatesAndCaps() {
        var items: [ClipboardItem] = []
        for text in ["a", "b", "c", "b"] {
            items = ClipboardStore.inserting(ClipboardItem(content: .text(text)), into: items, limit: 3)
        }
        #expect(items.map(\.content) == [.text("b"), .text("c"), .text("a")])
        items = ClipboardStore.inserting(ClipboardItem(content: .text("d")), into: items, limit: 3)
        #expect(items.map(\.content) == [.text("d"), .text("b"), .text("c")])
    }

    @Test func readsTextFilesAndImagesButSkipsConcealed() throws {
        let pasteboard = NSPasteboard(name: .init("NotchDeckTest.\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }

        pasteboard.clearContents()
        pasteboard.setString("hello", forType: .string)
        #expect(ClipboardStore.read(pasteboard, includeImages: true)?.content == .text("hello"))

        // A password manager marks its copies concealed: never recorded.
        pasteboard.clearContents()
        pasteboard.declareTypes([.string, .init("org.nspasteboard.ConcealedType")], owner: nil)
        pasteboard.setString("hunter2", forType: .string)
        pasteboard.setString("", forType: .init("org.nspasteboard.ConcealedType"))
        #expect(ClipboardStore.read(pasteboard, includeImages: true) == nil)

        pasteboard.clearContents()
        let url = URL(fileURLWithPath: "/Applications")
        pasteboard.writeObjects([url as NSURL])
        #expect(ClipboardStore.read(pasteboard, includeImages: true)?.content == .files([url]))

        pasteboard.clearContents()
        let png = try #require(NSImage(size: NSSize(width: 4, height: 4), flipped: false) { rect in
            NSColor.red.setFill(); rect.fill(); return true
        }.tiffRepresentation)
        pasteboard.setData(png, forType: .tiff)
        #expect(ClipboardStore.read(pasteboard, includeImages: false) == nil)
        if case .image = ClipboardStore.read(pasteboard, includeImages: true)?.content {} else {
            Issue.record("expected an image clip")
        }
    }

    @Test func copyBackMovesToTopAndIsNotReRecorded() {
        let pasteboard = NSPasteboard(name: .init("NotchDeckTest.\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        let name = "NotchDeckClipboard.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let store = ClipboardStore(settings: SettingsStore(defaults: defaults), pasteboard: pasteboard)
        let item = ClipboardItem(content: .text("from history"))
        store.copy(item)
        #expect(pasteboard.string(forType: .string) == "from history")
        #expect(store.items.first?.content == .text("from history"))
        #expect(store.lastCopiedID == store.items.first?.id)
        // A private pasteboard is never gated by "Paste from Other Apps".
        #expect(ClipboardStore.currentAccess(pasteboard) == .allowed)
    }
}
