import CoreAudio
import Foundation
import Observation
import OSLog
import SwiftUI

nonisolated struct LyricLine: Equatable, Sendable {
    var time: TimeInterval
    var text: String
}

/// Parses LRC: `[mm:ss.xx] text`, several timestamps per line, and an `[offset:±ms]` tag.
nonisolated enum LRCParser {
    static func parse(_ lrc: String) -> [LyricLine] {
        var lines: [LyricLine] = []
        var offset: TimeInterval = 0
        let stamp = /\[(\d{1,3}):(\d{1,2}(?:[.:]\d{1,3})?)\]/
        for raw in lrc.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.lowercased().hasPrefix("[offset:"), let value = Double(line.dropFirst(8).dropLast().trimmingCharacters(in: .whitespaces)) {
                offset = value / 1000
                continue
            }
            let matches = line.matches(of: stamp)
            guard !matches.isEmpty, let last = matches.last else { continue }
            let text = String(line[last.range.upperBound...]).trimmingCharacters(in: .whitespaces)
            for match in matches {
                let minutes = Double(match.output.1) ?? 0
                let seconds = Double(match.output.2.replacingOccurrences(of: ":", with: ".")) ?? 0
                lines.append(LyricLine(time: minutes * 60 + seconds, text: text))
            }
        }
        // A positive LRC offset means "lyrics come earlier".
        return lines.map { LyricLine(time: max(0, $0.time - offset), text: $0.text) }.sorted { $0.time < $1.time }
    }

    /// The line playing at `position` (the last one that has started), or nil before the first.
    static func lineIndex(in lines: [LyricLine], at position: TimeInterval) -> Int? {
        var low = 0, high = lines.count - 1, found: Int?
        while low <= high {
            let mid = (low + high) / 2
            if lines[mid].time <= position { found = mid; low = mid + 1 } else { high = mid - 1 }
        }
        return found
    }
}

/// Time-synced lyrics for the playing track from LRCLIB (lrclib.net: free, no account). Only runs
/// when Lyrics is on; each new track sends its title, artist, album and length to lrclib.net.
@Observable
final class LyricsStore {
    enum State: Equatable {
        case off
        case loading
        case synced([LyricLine])
        /// Lyrics exist but without timings, so there's nothing to follow along with.
        case unsynced
        case instrumental
        case notFound
        case failed
    }

    /// Lines are shown a touch early so they're readable as they're sung.
    static let lead: TimeInterval = 0.1
    /// Redraws land this far after a line's start, so rounding never shows the previous line.
    static let scheduleSlack: TimeInterval = 0.02

    private(set) var state: State = .off
    private(set) var trackKey: String?

    @ObservationIgnored private let settings: SettingsStore
    @ObservationIgnored private let media: NowPlayingStore
    @ObservationIgnored private let session: URLSession
    @ObservationIgnored private var cache: [String: State] = [:]
    @ObservationIgnored private var fetchTask: Task<Void, Never>?
    @ObservationIgnored private let logger = Logger(subsystem: "com.notchdeck.NotchDeck", category: "Lyrics")

    init(settings: SettingsStore, media: NowPlayingStore, session: URLSession = .shared) {
        self.settings = settings
        self.media = media
        self.session = session
    }

    var lines: [LyricLine] {
        if case .synced(let lines) = state { return lines }
        return []
    }

    /// Lyrics are on, music is playing and timed lyrics were found: the notch grows a lyric line.
    var isShowing: Bool {
        settings.lyricsEnabled && media.isPlaying && !lines.isEmpty
    }

    /// Where in the song the listener is (not the player): the player's position minus the output
    /// device's delay (Bluetooth headphones: ~150–250 ms), plus the lead and the user's nudge.
    func lyricPosition(at date: Date) -> TimeInterval {
        media.position(at: date) - OutputLatency.current() + Self.lead + settings.lyricsOffset
    }

    func currentLine(at date: Date) -> String? {
        let lines = lines
        guard !lines.isEmpty else { return nil }
        // A millisecond of tolerance: at a scheduled redraw the position equals the line's start.
        let position = lyricPosition(at: date) + 0.001
        guard let index = LRCParser.lineIndex(in: lines, at: position) else { return "♪" }
        let text = lines[index].text
        return text.isEmpty ? "♪" : text
    }

    /// Wall-clock times at which the shown line changes, from `now` on (assuming playback continues;
    /// the strip re-plans whenever playback state changes). Lets the strip redraw only when needed.
    func upcomingLineChanges(from now: Date, limit: Int = 200) -> [Date] {
        let lines = lines
        guard media.isPlaying, !lines.isEmpty else { return [now] }
        let position = lyricPosition(at: now)
        let next = (LRCParser.lineIndex(in: lines, at: position + 0.001) ?? -1) + 1
        guard next < lines.count else { return [now] }
        return [now] + lines[next..<min(lines.count, next + limit)].map {
            now.addingTimeInterval($0.time - position + Self.scheduleSlack)
        }
    }

    /// Called when the track or the setting changes.
    func update() {
        guard settings.lyricsEnabled, let snapshot = media.snapshot, !snapshot.title.isEmpty else {
            fetchTask?.cancel()
            trackKey = nil
            state = .off
            return
        }
        let key = [snapshot.artist, snapshot.title, snapshot.album].joined(separator: "\u{1F}")
        guard key != trackKey else { return }
        trackKey = key
        if let cached = cache[key] {
            state = cached
            return
        }
        state = .loading
        fetchTask?.cancel()
        let request = Request(title: snapshot.title, artist: snapshot.artist, album: snapshot.album, duration: snapshot.duration)
        let session = session
        fetchTask = Task { [weak self] in
            let result = await Self.fetch(request, session: session)
            guard !Task.isCancelled, let self, self.trackKey == key else { return }
            if result != .failed { self.remember(result, for: key) }
            self.state = result
        }
    }

    private func remember(_ state: State, for key: String) {
        if cache.count > 60 { cache.removeAll() }
        cache[key] = state
    }

    // MARK: LRCLIB

    nonisolated struct Request: Sendable {
        var title: String
        var artist: String
        var album: String
        var duration: TimeInterval
    }

    nonisolated struct LRCLIBTrack: Decodable, Sendable {
        var duration: Double?
        var instrumental: Bool?
        var plainLyrics: String?
        var syncedLyrics: String?
    }

    nonisolated static func state(from track: LRCLIBTrack) -> State {
        if let synced = track.syncedLyrics, !synced.isEmpty {
            let lines = LRCParser.parse(synced)
            if !lines.isEmpty { return .synced(lines) }
        }
        if track.instrumental == true { return .instrumental }
        if let plain = track.plainLyrics, !plain.isEmpty { return .unsynced }
        return .notFound
    }

    nonisolated static func fetch(_ request: Request, session: URLSession) async -> State {
        var exact = URLComponents(string: "https://lrclib.net/api/get")!
        exact.queryItems = [
            URLQueryItem(name: "track_name", value: request.title),
            URLQueryItem(name: "artist_name", value: request.artist),
            URLQueryItem(name: "album_name", value: request.album),
            URLQueryItem(name: "duration", value: String(Int(request.duration.rounded()))),
        ]
        do {
            if let track: LRCLIBTrack = try await get(exact.url!, session: session) {
                let state = state(from: track)
                if case .synced = state { return state }
            }
            // No exact match (album or length differs): search and take the closest timed result.
            var search = URLComponents(string: "https://lrclib.net/api/search")!
            search.queryItems = [URLQueryItem(name: "track_name", value: request.title), URLQueryItem(name: "artist_name", value: request.artist)]
            let results: [LRCLIBTrack] = try await get(search.url!, session: session) ?? []
            let timed = results.filter { !($0.syncedLyrics ?? "").isEmpty }
            let best = timed.min { abs(($0.duration ?? 0) - request.duration) < abs(($1.duration ?? 0) - request.duration) }
            if let best, request.duration <= 0 || abs((best.duration ?? request.duration) - request.duration) <= 4 {
                return state(from: best)
            }
            if results.contains(where: { $0.instrumental == true }) { return .instrumental }
            return results.isEmpty ? .notFound : .unsynced
        } catch {
            return .failed
        }
    }

    /// nil on 404.
    nonisolated private static func get<T: Decodable>(_ url: URL, session: URLSession) async throws -> T? {
        var request = URLRequest(url: url)
        request.timeoutInterval = 10
        // LRCLIB asks clients to identify themselves.
        request.setValue("NotchDeck/1.0 (macOS notch utility)", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status == 404 { return nil }
        guard (200..<300).contains(status) else { throw URLError(.badServerResponse) }
        return try JSONDecoder().decode(T.self, from: data)
    }
}

/// The lyric line under the collapsed notch (the notch grows to make room while lyrics show).
struct LyricsStrip: View {
    @Environment(LyricsStore.self) private var lyrics
    @Environment(NowPlayingStore.self) private var media

    var body: some View {
        // Redraws exactly when the next line starts (re-planned when playback changes: pause,
        // seek, next track), instead of polling.
        let _ = media.snapshot
        TimelineView(.explicit(lyrics.upcomingLineChanges(from: Date()))) { context in
            let line = lyrics.currentLine(at: context.date) ?? ""
            Text(line)
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(.white.opacity(line == "♪" ? 0.6 : 0.95))
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 14)
                .id(line)
                .transition(.asymmetric(insertion: .move(edge: .bottom).combined(with: .opacity), removal: .opacity))
                .animation(.easeOut(duration: 0.25), value: line)
        }
        .clipped()
        .accessibilityLabel("Lyrics")
    }
}

/// How long audio takes to come out of the current output device (CoreAudio's device + stream
/// latency and buffer). Bluetooth headphones report ~150–250 ms; built-in speakers a few ms.
/// Cached for a couple of seconds (it's read on every lyric redraw).
enum OutputLatency {
    private static var cached: (value: TimeInterval, at: Date)?

    static func current(now: Date = Date()) -> TimeInterval {
        if let cached, now.timeIntervalSince(cached.at) < 2 { return cached.value }
        let value = measure() ?? 0
        cached = (value, now)
        return value
    }

    static func measure() -> TimeInterval? {
        var device = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                                 mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device) == noErr,
              device != 0 else { return nil }

        func frames(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector, _ scope: AudioObjectPropertyScope) -> UInt32 {
            var value = UInt32(0)
            var size = UInt32(MemoryLayout<UInt32>.size)
            var address = AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
            return AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr ? value : 0
        }
        var rate = Float64(0)
        var rateSize = UInt32(MemoryLayout<Float64>.size)
        var rateAddress = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyNominalSampleRate,
                                                     mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(device, &rateAddress, 0, nil, &rateSize, &rate) == noErr, rate > 0 else { return nil }

        var total = frames(device, kAudioDevicePropertyLatency, kAudioDevicePropertyScopeOutput)
            + frames(device, kAudioDevicePropertySafetyOffset, kAudioDevicePropertyScopeOutput)
            + frames(device, kAudioDevicePropertyBufferFrameSize, kAudioDevicePropertyScopeOutput)
        var streamsAddress = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreams,
                                                        mScope: kAudioDevicePropertyScopeOutput, mElement: kAudioObjectPropertyElementMain)
        var streamsSize = UInt32(0)
        if AudioObjectGetPropertyDataSize(device, &streamsAddress, 0, nil, &streamsSize) == noErr, streamsSize >= 4 {
            var streams = [AudioStreamID](repeating: 0, count: Int(streamsSize) / MemoryLayout<AudioStreamID>.size)
            if AudioObjectGetPropertyData(device, &streamsAddress, 0, nil, &streamsSize, &streams) == noErr, let first = streams.first {
                total += frames(first, kAudioStreamPropertyLatency, kAudioObjectPropertyScopeGlobal)
            }
        }
        let seconds = Double(total) / rate
        return seconds < 2 ? seconds : nil   // ignore nonsense
    }
}
