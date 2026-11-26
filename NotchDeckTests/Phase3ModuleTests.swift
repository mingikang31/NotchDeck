import AppKit
import Foundation
import Testing
@testable import NotchDeck

// MARK: - Calendar

struct MeetingLinkParserTests {
    @Test(arguments: [
        ("Join: https://us02web.zoom.us/j/81234567890?pwd=abc123", MeetingProvider.zoom),
        ("meet.google.com/abc-defg-hij", .googleMeet),
        ("Click https://teams.microsoft.com/l/meetup-join/19%3ameeting_x/0?context=%7b%7d here", .teams),
        ("https://teams.live.com/meet/9876543210", .teams),
        ("Webex: https://acme.webex.com/acme/j.php?MTID=m123", .webex),
    ])
    func detectsProviders(text: String, provider: MeetingProvider) throws {
        let link = try #require(MeetingLinkParser.link(in: text))
        #expect(link.provider == provider)
        #expect(link.url.scheme == "https")
    }

    @Test func ignoresOrdinaryLinksAndLookalikes() {
        #expect(MeetingLinkParser.link(in: "Agenda: https://docs.google.com/document/d/1") == nil)
        #expect(MeetingLinkParser.link(in: "https://notzoom.us.evil.example/j/1") == nil)
        #expect(MeetingLinkParser.link(in: "Room 4B, no link") == nil)
    }

    @Test func prefersEarlierFieldsAndSkipsEmptyOnes() throws {
        let link = try #require(MeetingLinkParser.firstLink(in: [
            nil, "", "https://meet.google.com/aaa-bbbb-ccc", "https://zoom.us/j/1",
        ]))
        #expect(link.provider == .googleMeet)
    }
}

struct UpcomingEventTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func event(startsIn minutes: Double, lasting duration: Double = 30) -> UpcomingEvent {
        let start = now.addingTimeInterval(minutes * 60)
        return UpcomingEvent(id: "e", title: "Design Sync", start: start, end: start.addingTimeInterval(duration * 60))
    }

    @Test func countdownFormats() {
        #expect(event(startsIn: 11.2).countdown(from: now) == "In 12m")
        #expect(event(startsIn: 0.2).countdown(from: now) == "In 1m")
        #expect(event(startsIn: -5).countdown(from: now) == "Now")
        #expect(event(startsIn: 65).countdown(from: now) == "In 1h 05m")
        #expect(event(startsIn: 300).countdown(from: now).contains(":"))
    }

    @Test func ongoingWindow() {
        #expect(event(startsIn: -5).isOngoing(at: now))
        #expect(!event(startsIn: -40).isOngoing(at: now))
        #expect(!event(startsIn: 5).isOngoing(at: now))
    }
}

// MARK: - Live activities

struct LiveActivityPriorityTests {
    @Test func nothingWhenIdle() {
        #expect(LiveActivityCoordinator.resolve(isMediaPlaying: false, event: nil) == nil)
        #expect(LiveActivityCoordinator.resolve(isMediaPlaying: false, event: ("e", 3 * 3600, false)) == nil)
    }

    @Test func imminentMeetingBeatsMusic() {
        #expect(LiveActivityCoordinator.resolve(isMediaPlaying: true, event: ("e", 10 * 60, false)) == .upcomingEvent(id: "e"))
    }

    @Test func musicBeatsLaterMeeting() {
        #expect(LiveActivityCoordinator.resolve(isMediaPlaying: true, event: ("e", 40 * 60, false)) == .nowPlaying)
        #expect(LiveActivityCoordinator.resolve(isMediaPlaying: false, event: ("e", 40 * 60, false)) == .upcomingEvent(id: "e"))
    }

    @Test func longRunningMeetingYieldsToMusic() {
        #expect(LiveActivityCoordinator.resolve(isMediaPlaying: true, event: ("e", -3 * 60, true)) == .upcomingEvent(id: "e"))
        #expect(LiveActivityCoordinator.resolve(isMediaPlaying: true, event: ("e", -25 * 60, true)) == .nowPlaying)
        #expect(LiveActivityCoordinator.resolve(isMediaPlaying: false, event: ("e", -25 * 60, true)) == .upcomingEvent(id: "e"))
    }
}

struct WingGeometryTests {
    private let g = NotchGeometry.compute(
        screenFrame: CGRect(x: 0, y: 0, width: 1512, height: 982),
        visibleFrame: CGRect(x: 0, y: 61, width: 1512, height: 888),
        safeAreaTop: 32,
        auxiliaryTopLeft: CGRect(x: 0, y: 950, width: 663.5, height: 32),
        auxiliaryTopRight: CGRect(x: 848.5, y: 950, width: 663.5, height: 32),
        preset: .medium
    )

    @Test func wingsWidenCollapsedBodySymmetrically() {
        let body = g.bodyRect(for: .collapsed, wing: 34)
        #expect(body.width == CGFloat(253)) // 185 pt cutout + 2 × 34 pt wings
        #expect(body.midX == g.cutout.midX)
        #expect(body.height == g.cutout.height)
    }

    @Test func wingsExtendTheHoverZone() {
        let besideNotch = CGPoint(x: g.cutout.minX - 20, y: 970)
        #expect(!g.interactionZone(for: .collapsed).contains(besideNotch))
        #expect(g.interactionZone(for: .collapsed, wing: 34).contains(besideNotch))
    }

    @Test func oversizedWingsAreClampedInsideThePanel() {
        let shape = g.shapeRect(for: .peek, wing: 10_000)
        #expect(g.panelFrame.contains(shape))
        #expect(g.metrics(for: .collapsed, wing: -5).bodySize.width == g.cutout.width)
    }
}

// MARK: - Media

struct MediaSnapshotTests {
    private func list(_ items: [NSAppleEventDescriptor]) -> NSAppleEventDescriptor {
        let list = NSAppleEventDescriptor.list()
        for (index, item) in items.enumerated() { list.insert(item, at: index + 1) }
        return list
    }

    @Test func parsesMusicReply() throws {
        let reply = list([
            .init(string: "playing"), .init(string: "A1B2C3"), .init(string: "Song"), .init(string: "Artist"),
            .init(string: "Album"), .init(double: 245.5), .init(double: 12.25),
        ])
        let snapshot = try #require(MediaSnapshot.parse(reply, source: .music))
        #expect(snapshot.state == .playing)
        #expect(snapshot.trackID == "A1B2C3")
        #expect(snapshot.duration == 245.5)
        #expect(snapshot.position == 12.25)
        #expect(snapshot.artworkURL == nil)
    }

    @Test func parsesSpotifyReplyWithArtworkURL() throws {
        let reply = list([
            .init(string: "paused"), .init(string: "spotify:track:1"), .init(string: "Song"), .init(string: "Artist"),
            .init(string: "Album"), .init(double: 180), .init(double: 42), .init(string: "https://i.scdn.co/image/abc"),
        ])
        let snapshot = try #require(MediaSnapshot.parse(reply, source: .spotify))
        #expect(snapshot.state == .paused)
        #expect(snapshot.artworkURL?.host == "i.scdn.co")
    }

    @Test func stoppedOrMalformedRepliesYieldNothing() {
        #expect(MediaSnapshot.parse(list([.init(string: "stopped")]), source: .music) == nil)
        #expect(MediaSnapshot.parse(list([.init(string: "playing"), .init(string: "x")]), source: .music) == nil)
        #expect(MediaSnapshot.parse(.null(), source: .music) == nil)
    }

    @Test func preferredSourcePicksThePlayingOne() {
        let base = MediaSnapshot(source: .music, state: .paused, trackID: "m", title: "", artist: "", album: "", duration: 1, position: 0)
        var spotify = base
        spotify.source = .spotify
        spotify.state = .playing
        #expect(NowPlayingStore.preferred([base, spotify], lastActive: .music)?.source == .spotify)
        #expect(NowPlayingStore.preferred([base], lastActive: nil)?.source == .music)
        #expect(NowPlayingStore.preferred([], lastActive: .music) == nil)
    }

    @Test func paletteFindsTheVibrantColor() throws {
        let size = 20
        let context = try #require(CGContext(
            data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.setFillColor(CGColor(gray: 0.5, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: size, height: size))
        context.setFillColor(CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 6, height: 6))
        let palette = ArtworkPalette.extract(from: try #require(context.makeImage()))
        #expect(palette.count == 2)
        #expect(palette[0].red > 0.9 && palette[0].green < 0.1)
        #expect(abs(palette[1].green - palette[1].blue) < 0.02) // average stays on the grey axis
    }

    @Test func outputDeviceEnumerationIsSafe() {
        let devices = AudioOutputDevices.all()
        if let id = AudioOutputDevices.defaultDeviceID() {
            #expect(devices.contains { $0.id == id })
        }
    }
}

// MARK: - File Tray

struct FileTrayStoreTests {
    private let root: URL

    init() throws {
        root = FileManager.default.temporaryDirectory.appending(path: "NotchDeckTrayTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    private func makeFile(_ name: String, contents: String = "hello") throws -> URL {
        let url = root.appending(path: "source").appending(path: name)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(contents.utf8).write(to: url)
        return url
    }

    private func store() -> FileTrayStore {
        FileTrayStore(directory: root.appending(path: "support", directoryHint: .isDirectory))
    }

    @Test func referencedFilesPersistAndDeduplicate() throws {
        let file = try makeFile("report.pdf")
        let tray = store()
        tray.add(fileURLs: [file, file])
        #expect(tray.items.count == 1)
        #expect(tray.items[0].byteCount == 5)
        #expect(!tray.items[0].isStaged)

        let reloaded = store()
        #expect(reloaded.items.count == 1)
        #expect(reloaded.url(for: reloaded.items[0])?.lastPathComponent == "report.pdf")
    }

    @Test func droppedTextIsStagedAndRemovedWithItsItem() throws {
        let tray = store()
        tray.add(text: "https://example.com/some/link")
        tray.add(text: "   ")
        let item = try #require(tray.items.first)
        #expect(tray.items.count == 1)
        let staged = try #require(tray.url(for: item))
        #expect(try String(contentsOf: staged, encoding: .utf8) == "https://example.com/some/link")

        tray.remove([item.id])
        #expect(tray.items.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: staged.path))
    }

    @Test func referencesToDeletedFilesArePruned() throws {
        let file = try makeFile("temp.txt")
        let tray = store()
        tray.add(fileURLs: [file])
        try FileManager.default.removeItem(at: file)
        #expect(tray.availableItems.isEmpty)
        tray.pruneMissing()
        #expect(tray.items.isEmpty)
    }

    @Test func selectionDrivesActionTargets() throws {
        let tray = store()
        tray.add(fileURLs: [try makeFile("a.txt"), try makeFile("b.txt")])
        #expect(tray.actionTargets.count == 2)
        tray.toggleSelection(tray.items[1].id)
        #expect(tray.actionTargets.map(\.displayName) == ["b.txt"])
    }

    @Test func zipsMultipleFilesIntoOneArchive() async throws {
        let tray = store()
        tray.add(fileURLs: [try makeFile("a.txt", contents: "aaa"), try makeFile("b.txt", contents: "bbb")])
        await tray.zipTargets()

        let zip = try #require(tray.items.last)
        #expect(zip.isStaged)
        #expect(zip.displayName.hasSuffix(".zip"))
        let entries = try listZip(try #require(tray.url(for: zip)))
        #expect(entries.contains { $0.hasSuffix("a.txt") })
        #expect(entries.contains { $0.hasSuffix("b.txt") })
        #expect(tray.selection == [zip.id])
    }

    @Test func zipsASingleFileWithoutExtraNesting() async throws {
        let tray = store()
        tray.add(fileURLs: [try makeFile("notes.md", contents: "# hi")])
        await tray.zipTargets()
        let zip = try #require(tray.items.last)
        #expect(zip.displayName == "notes.zip")
        #expect(try listZip(try #require(tray.url(for: zip))) == ["notes.md"])
    }

    private func listZip(_ url: URL) throws -> [String] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/zipinfo")
        process.arguments = ["-1", url.path]
        let pipe = Pipe()
        process.standardOutput = pipe
        try process.run()
        process.waitUntilExit()
        return String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            .split(separator: "\n").map(String.init).filter { !$0.hasPrefix("__MACOSX") }
    }
}

// MARK: - Expanded shell

struct ModuleSelectionTests {
    @Test func fallsBackToFirstEnabledModule() {
        #expect(ExpandedShellView.resolvedSelection(.calendar, enabled: [.media, .calendar]) == .calendar)
        #expect(ExpandedShellView.resolvedSelection(.calendar, enabled: [.media]) == .media)
        #expect(ExpandedShellView.resolvedSelection(nil, enabled: [.fileTray]) == .fileTray)
        #expect(ExpandedShellView.resolvedSelection(.media, enabled: []) == nil)
    }

    @Test func shippedModulesAreAvailable() {
        #expect(NotchModule.media.isAvailable && NotchModule.fileTray.isAvailable && NotchModule.calendar.isAvailable)
        #expect(NotchModule.aiChat.isAvailable && NotchModule.agentHooks.isAvailable)
        #expect(NotchModule.pomodoro.isAvailable && NotchModule.mirror.isAvailable)
        // Every shortcut drives a shipped module now (Phase 6 done).
        #expect(ShortcutAction.allCases.allSatisfy { $0.pendingModule == nil })
    }
}
