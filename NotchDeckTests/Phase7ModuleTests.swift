import AppKit
import Foundation
import SwiftUI
import Testing
@testable import NotchDeck

// MARK: Pricing

struct ModelPricingTests {
    @Test func normalizesProviderAndDateSuffixes() {
        #expect(ModelPricing.normalize("claude-sonnet-4-5-20250929") == "claude-sonnet-4-5")
        #expect(ModelPricing.normalize("anthropic.claude-opus-5-5") == "claude-opus-5-5")
        #expect(ModelPricing.normalize("claude-opus-4-5@20251101") == "claude-opus-4-5")
        #expect(ModelPricing.normalize("models/gemini-2.5-pro") == "gemini-2.5-pro")
    }

    @Test func looksUpExactBeforeWildcardAndCustomBeforeBuiltIn() throws {
        #expect(ModelPricing.price(for: "claude-opus-5-5", custom: [])?.input == 4)
        #expect(ModelPricing.price(for: "claude-opus-5", custom: [])?.input == 5)        // not confused with opus-5-5
        #expect(ModelPricing.price(for: "claude-sonnet-4-5-20250929", custom: [])?.output == 15)
        #expect(ModelPricing.price(for: "gpt-5.6-terra", custom: []) == nil)
        let custom = [ModelPrice.row("gpt-5*", 1, 8), ModelPrice.row("gpt-5.6*", 2, 10), ModelPrice.row("claude-opus-5-5", 3, 15)]
        #expect(ModelPricing.price(for: "gpt-5.6-terra", custom: custom)?.input == 2)   // longest wildcard wins
        #expect(ModelPricing.price(for: "gpt-5-codex", custom: custom)?.input == 1)
        #expect(ModelPricing.price(for: "claude-opus-5-5", custom: custom)?.input == 3)  // user override
    }

    @Test func costUsesEveryTokenClass() throws {
        let opus = try #require(ModelPricing.price(for: "claude-opus-5-5", custom: []))
        let tokens = TokenCounts(input: 1_000_000, cacheWrite5m: 1_000_000, cacheWrite1h: 1_000_000, cacheRead: 1_000_000, output: 1_000_000)
        #expect(abs(opus.cost(of: tokens) - (4 + 5 + 8 + 0.20 + 20)) < 1e-9)
        #expect(abs(opus.cost(of: TokenCounts(output: 1_000_000), multiplier: 2) - 40) < 1e-9)   // fast mode
        // The pricing page's worked example: 10K uncached + 40K cache reads + 15K output on Opus 5.5.
        #expect(abs(opus.cost(of: TokenCounts(input: 10_000, cacheRead: 40_000, output: 15_000)) - 0.348) < 1e-9)
    }

    @Test func haikuLongPromptTier() throws {
        let haiku = try #require(ModelPricing.price(for: "claude-haiku-5-5", custom: []))
        #expect(abs(haiku.cost(of: TokenCounts(input: 100_000, output: 0)) - 0.01) < 1e-9)          // at the threshold
        #expect(abs(haiku.cost(of: TokenCounts(input: 50_000, cacheRead: 60_000)) - (0.05 * 0.5 + 0.06 * 0.05)) < 1e-9)
    }

    @Test func formatting() {
        #expect(UsageFormat.tokens(950) == "950")
        #expect(UsageFormat.tokens(12_400) == "12K")
        #expect(UsageFormat.tokens(2_340_000) == "2.3M")
        var totals = UsageStore.Totals()
        totals.cost = 4.1
        #expect(UsageFormat.cost(totals, estimate: true) == "≈$4.10")
        totals.unpricedTokens = 10
        #expect(UsageFormat.cost(totals, estimate: false) == "$4.10+")
        #expect(UsageFormat.cost(UsageStore.Totals(unpricedTokens: 5), estimate: false) == "—")
    }
}

// MARK: Log parsing

struct UsageLogParsingTests {
    static func claudeLine(id: String = "msg_1", request: String = "req_1", model: String = "claude-opus-5-5",
                           date: String = "2026-11-26T10:00:00.000Z", toolName: String? = nil, speed: String = "standard") -> Data {
        var content: [[String: Any]] = [["type": "text", "text": "hi"]]
        if let toolName { content.append(["type": "tool_use", "name": toolName, "input": [:] as [String: Any]]) }
        let json: [String: Any] = [
            "type": "assistant", "timestamp": date, "sessionId": "s1", "cwd": "/Users/me/Developer/NotchDeck", "requestId": request,
            "message": [
                "id": id, "model": model, "content": content,
                "usage": [
                    "input_tokens": 10, "cache_read_input_tokens": 300, "output_tokens": 50,
                    "cache_creation_input_tokens": 1000, "speed": speed,
                    "cache_creation": ["ephemeral_5m_input_tokens": 200, "ephemeral_1h_input_tokens": 800],
                ] as [String: Any],
            ] as [String: Any],
        ]
        return try! JSONSerialization.data(withJSONObject: json)
    }

    @Test func claudeCodeAssistantLine() throws {
        let entry = try #require(ClaudeCodeLog.entry(from: Self.claudeLine(toolName: "mcp__github__create_issue", speed: "fast")))
        #expect(entry.record.tokens == TokenCounts(input: 10, cacheWrite5m: 200, cacheWrite1h: 800, cacheRead: 300, output: 50))
        #expect(entry.record.id == "cc:msg_1:req_1")
        #expect(entry.record.project == "NotchDeck")
        #expect(entry.record.priceMultiplier == 2)
        #expect(entry.mcpServers == ["github"])
        #expect(ClaudeCodeLog.entry(from: Self.claudeLine(model: "<synthetic>")) == nil)
        #expect(ClaudeCodeLog.entry(from: Data(#"{"type":"user","message":{"content":"usage"}}"#.utf8)) == nil)
    }

    @Test func fastTimestampParsing() {
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        for string in ["2026-11-26T10:00:00.123Z", "2024-02-29T23:59:59.5Z", "1999-01-01T00:00:00.000Z"] {
            let fast = ClaudeCodeLog.fastISODate(string)
            #expect(fast != nil)
            #expect(abs((fast?.timeIntervalSince1970 ?? 0) - (iso.date(from: string)?.timeIntervalSince1970 ?? -1)) < 0.001)
        }
        #expect(ClaudeCodeLog.fastISODate("2026-11-26T10:00:00Z") == ISO8601DateFormatter().date(from: "2026-11-26T10:00:00Z"))
        #expect(ClaudeCodeLog.fastISODate("2026-11-26T10:00:00+09:00") == nil)   // falls back to the formatter
        #expect(ClaudeCodeLog.parseDate("2026-11-26T10:00:00+09:00") != nil)
        #expect(ModelPricing.normalize("anthropic.claude-sonnet-4-5-20250929-v1:0") == "claude-sonnet-4-5")
    }

    @Test func claudeLimitStatus() throws {
        let line = Data(#"{"type":"assistant","timestamp":"2026-11-26T10:00:00Z","quotaLimits":{"status":"allowed_warning","resetsAt":1800000000,"rateLimitType":"five_hour"}}"#.utf8)
        let limit = try #require(ClaudeCodeLog.limitStatus(from: line))
        #expect(limit.status == "allowed_warning")
        #expect(limit.kindDescription == "5-hour limit")
        #expect(limit.resetsAt == Date(timeIntervalSince1970: 1_800_000_000))
    }

    static func codexLines() -> [Data] {
        [
            #"{"timestamp":"2026-11-26T10:00:00Z","type":"session_meta","payload":{"id":"cx-session","cwd":"/Users/me/proj"}}"#,
            #"{"timestamp":"2026-11-26T10:00:01Z","type":"turn_context","payload":{"model":"gpt-5.6-terra"}}"#,
            #"{"timestamp":"2026-11-26T10:00:05Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"total_tokens":1200},"last_token_usage":{"input_tokens":1000,"cached_input_tokens":400,"output_tokens":200,"total_tokens":1200}},"rate_limits":{"plan_type":"plus","primary":{"used_percent":12.5,"window_minutes":300,"resets_at":1800000000}}}}"#,
            // Same total again (a repeated report): not counted twice.
            #"{"timestamp":"2026-11-26T10:00:06Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"total_tokens":1200},"last_token_usage":{"input_tokens":1000,"cached_input_tokens":400,"output_tokens":200,"total_tokens":1200}},"rate_limits":null}}"#,
            #"{"timestamp":"2026-11-26T10:01:00Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"total_tokens":1500},"last_token_usage":{"input_tokens":250,"cached_input_tokens":0,"output_tokens":50,"total_tokens":300}}}}"#,
        ].map { Data($0.utf8) }
    }

    @Test func codexTokenCountEvents() throws {
        var state = CodexLog.FileState()
        var records: [UsageRecord] = []
        var plans: [CodexPlanStatus] = []
        for line in Self.codexLines() {
            let (record, plan) = CodexLog.process(line, state: &state, fileID: "rollout-1")
            if let record { records.append(record) }
            if let plan { plans.append(plan) }
        }
        #expect(records.count == 2)
        #expect(records[0].tokens == TokenCounts(input: 600, cacheRead: 400, output: 200))   // cached split out
        #expect(records[0].model == "gpt-5.6-terra")
        #expect(records[0].sessionID == "cx-session")
        #expect(records[0].project == "proj")
        #expect(records.map(\.id) == ["cx:rollout-1:1", "cx:rollout-1:2"])
        let plan = try #require(plans.first)
        #expect(plan.plan == "plus")
        #expect(plan.primary?.usedPercent == 12.5)
        #expect(plan.primary?.description == "5-hour window")
    }

    @Test func mcpConfigs() {
        let claude = Data(#"{"mcpServers":{"github":{"type":"http","url":"https://x"},"files":{"command":"npx"}},"projects":{"/p/a":{"mcpServers":{"db":{"command":"db"}}},"/p/b":{"mcpServers":{"other":{}}}}}"#.utf8)
        let servers = MCPConfigReader.claudeServers(claudeJSON: claude, projectDirectories: ["/p/a"])
        #expect(servers.map(\.name) == ["db", "files", "github"])
        #expect(servers.first { $0.name == "github" }?.transport == "http")
        #expect(servers.first { $0.name == "db" }?.scope == "project: a")

        let toml = """
        model = "gpt-5"
        [mcp_servers.node_repl]
        command = "node"
        [mcp_servers.node_repl.env]
        FOO = "bar"
        [mcp_servers."remote-docs"]
        url = "https://docs.example/mcp"
        [profiles.fast]
        model = "x"
        """
        let codex = MCPConfigReader.codexServers(configTOML: toml)
        #expect(codex.map(\.name) == ["node_repl", "remote-docs"])
        #expect(codex.map(\.transport) == ["stdio", "http"])
    }
}

// MARK: Scanner and store

struct UsageStoreTests {
    private func makeHome() throws -> URL {
        let home = FileManager.default.temporaryDirectory.appending(path: "NDUsage-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home.appending(path: ".claude/projects/-p"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: home.appending(path: ".codex/sessions/2026/11/26"), withIntermediateDirectories: true)
        return home
    }

    private func append(_ lines: [Data], to url: URL, trailingNewline: Bool = true) throws {
        var data = Data()
        for (index, line) in lines.enumerated() {
            data.append(line)
            if trailingNewline || index < lines.count - 1 { data.append(0x0A) }
        }
        if FileManager.default.fileExists(atPath: url.path) {
            let handle = try FileHandle(forWritingTo: url)
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
            try handle.close()
        } else {
            try data.write(to: url)
        }
    }

    @Test func scansIncrementallyAndDeduplicates() async throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let now = ISO8601DateFormatter().date(from: "2026-11-26T12:00:00Z")!
        let transcript = home.appending(path: ".claude/projects/-p/s1.jsonl")
        // The same message written twice (one line per content block) counts once.
        try append([UsageLogParsingTests.claudeLine(), UsageLogParsingTests.claudeLine()], to: transcript)
        try append(UsageLogParsingTests.codexLines(), to: home.appending(path: ".codex/sessions/2026/11/26/rollout-1.jsonl"))

        let scanner = UsageScanner(home: home)
        let first = await scanner.scan(now: now)
        #expect(first.newRecords.filter { $0.source == .claudeCode }.count == 1)
        #expect(first.newRecords.filter { $0.source == .codex }.count == 2)
        #expect(first.codexPlan?.primary?.usedPercent == 12.5)
        #expect(first.recentProjectDirectories == ["/Users/me/Developer/NotchDeck"])

        // Nothing new → nothing returned. A half-written line waits until it's complete.
        #expect(await scanner.scan(now: now).newRecords.isEmpty)
        let second = UsageLogParsingTests.claudeLine(id: "msg_2", date: "2026-11-26T11:00:00.000Z")
        try append([second.prefix(40)], to: transcript, trailingNewline: false)
        #expect(await scanner.scan(now: now).newRecords.isEmpty)
        try append([second.dropFirst(40)], to: transcript)
        let third = await scanner.scan(now: now)
        #expect(third.newRecords.map(\.id) == ["cc:msg_2:req_1"])
    }

    @Test func storeTotalsSessionsAndChatPersistence() async throws {
        let home = try makeHome()
        let support = home.appending(path: "support")
        defer { try? FileManager.default.removeItem(at: home) }
        let name = "NotchDeckUsage.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let settings = SettingsStore(defaults: defaults)

        let nowString = ISO8601DateFormatter().string(from: Date())
        try append([UsageLogParsingTests.claudeLine(date: nowString)], to: home.appending(path: ".claude/projects/-p/s1.jsonl"))

        let store = UsageStore(settings: settings, directory: support, home: home)
        store.recordChat(model: "claude-sonnet-5-5", provider: .anthropic, tokens: TokenCounts(input: 1000, output: 500))
        await store.refresh()

        let chat = store.totals(for: .aiChat, in: .today)
        #expect(chat.requests == 1)
        #expect(abs(chat.cost - (1000 * 2 + 500 * 10) / 1_000_000) < 1e-12)
        let code = store.totals(for: .claudeCode, in: .today)
        #expect(code.tokens.total == 10 + 200 + 800 + 300 + 50)
        #expect(code.cost > 0)
        #expect(store.activeSessions().first?.project == "NotchDeck")
        #expect(store.modelTotals(in: .today).count == 2)

        // Chat usage survives a relaunch; agent usage is re-read from the logs.
        let relaunched = UsageStore(settings: settings, directory: support, home: home)
        #expect(relaunched.totals(for: .aiChat, in: .today).requests == 1)

        // A model with no price shows as unpriced rather than $0.
        store.recordChat(model: "llama-local", provider: .openAICompatible, tokens: TokenCounts(input: 5, output: 5))
        #expect(store.totals(for: .aiChat, in: .today).unpricedTokens == 10)
    }

    @Test func rangeStarts() {
        let calendar = Calendar(identifier: .gregorian)
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        #expect(UsageStore.Range.today.start(from: now, calendar: calendar) == calendar.startOfDay(for: now))
        #expect(UsageStore.Range.week.start(from: now, calendar: calendar) < UsageStore.Range.today.start(from: now, calendar: calendar))
    }
}

// MARK: Chat usage parsing

struct ChatUsageParsingTests {
    @Test func anthropicStartAndDelta() throws {
        let start = #"{"type":"message_start","message":{"model":"claude-opus-5-5","usage":{"input_tokens":12,"cache_read_input_tokens":3000,"cache_creation_input_tokens":0,"output_tokens":1}}}"#
        let events = try #require(try AnthropicChatClient.events(from: start))
        #expect(events.contains(.usage(TokenCounts(input: 12, cacheRead: 3000, output: 1))))
        let delta = #"{"type":"message_delta","delta":{"stop_reason":"end_turn"},"usage":{"output_tokens":420}}"#
        let deltaEvents = try #require(try AnthropicChatClient.events(from: delta))
        #expect(deltaEvents == [.usage(TokenCounts(output: 420)), .stop(reason: "end_turn")])
        // The store merges cumulative reports field by field.
        #expect(TokenCounts(input: 12, cacheRead: 3000, output: 1).merged(with: TokenCounts(output: 420)) == TokenCounts(input: 12, cacheRead: 3000, output: 420))
    }

    @Test func geminiUsageMetadata() throws {
        let payload = #"{"candidates":[{"content":{"parts":[{"text":"hi"}]}}],"usageMetadata":{"promptTokenCount":100,"cachedContentTokenCount":40,"candidatesTokenCount":20,"thoughtsTokenCount":5}}"#
        let events = try #require(try GeminiChatClient.events(from: payload, modelID: "gemini-x"))
        #expect(events.first == .usage(TokenCounts(input: 60, cacheRead: 40, output: 25)))
        #expect(events.contains(.text("hi")))
    }

    @Test func openAICompatibleUsageChunk() throws {
        let payload = #"{"choices":[],"usage":{"prompt_tokens":90,"completion_tokens":30,"prompt_tokens_details":{"cached_tokens":10}}}"#
        let events = try #require(try OpenAICompatibleChatClient.events(from: payload))
        #expect(events == [.usage(TokenCounts(input: 80, cacheRead: 10, output: 30))])
        let body = OpenAICompatibleChatClient.body(for: ChatRequest(modelID: "m", systemPrompt: "", turns: [], maxTokens: 100,
                                                                     useRefusalFallbacks: false, useAdaptiveThinking: false))
        #expect((body["stream_options"] as? [String: Bool])?["include_usage"] == true)
    }
}

// MARK: Lyrics

struct LyricsTests {
    @Test func parsesLRC() {
        let lrc = """
        [ti:Song]
        [offset:+500]
        [00:12.50]First line
        [00:15.00][01:15.00]Chorus
        [00:20.10]
        not a lyric line
        """
        let lines = LRCParser.parse(lrc)
        #expect(lines.map(\.text) == ["First line", "Chorus", "", "Chorus"])
        #expect(abs(lines[0].time - 12.0) < 1e-9)     // +500 ms offset shows lines earlier
        #expect(abs(lines[3].time - 74.5) < 1e-9)
        #expect(LRCParser.lineIndex(in: lines, at: 5) == nil)
        #expect(LRCParser.lineIndex(in: lines, at: 14.9) == 1)
        #expect(LRCParser.lineIndex(in: lines, at: 200) == 3)
    }

    /// Regression: redraws are scheduled at a line's start; rounding must never show the previous line.
    @Test func lineChangesLandOnTheNewLine() {
        let lines = (0..<50).map { LyricLine(time: Double($0) * 2.37 + 0.13, text: "line \($0)") }
        for index in 1..<lines.count {
            let scheduled = lines[index].time + LyricsStore.scheduleSlack
            #expect(LRCParser.lineIndex(in: lines, at: scheduled + 0.001) == index)
        }
    }

    @Test func outputLatencyIsSane() {
        let latency = OutputLatency.measure() ?? 0
        #expect((0..<2).contains(latency))
    }

    @Test func lyricsOffsetClamps() {
        let name = "NotchDeckLyricsOffset.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let settings = SettingsStore(defaults: defaults)
        #expect(settings.lyricsOffset == 0)
        settings.lyricsOffset = 3
        #expect(settings.lyricsOffset == 1)
        settings.lyricsOffset = -0.34
        #expect(abs(settings.lyricsOffset - (-0.3)) < 1e-9)
        #expect(SettingsStore(defaults: defaults).lyricsOffset == settings.lyricsOffset)
    }

    /// Regression: the accent color was ignored whenever album art existed (i.e. always while playing).
    @Test func accentColorDrivesTheVisualizer() {
        let artwork: [Color] = [.red, .green]
        #expect(AccentColorChoice.teal.colors(artworkPalette: artwork) == AccentColorChoice.teal.gradient)
        #expect(AccentColorChoice.graphite.colors(artworkPalette: artwork) == AccentColorChoice.graphite.gradient)
        #expect(AccentColorChoice.artwork.colors(artworkPalette: artwork) == artwork)
        #expect(AccentColorChoice.artwork.colors(artworkPalette: []) == AccentColorChoice.rose.gradient)
        #expect(AccentColorChoice.allCases.first == .artwork)
    }

    @Test func lrclibStates() {
        #expect(LyricsStore.state(from: .init(duration: 200, instrumental: false, plainLyrics: "a", syncedLyrics: "[00:01.00]a")) == .synced([LyricLine(time: 1, text: "a")]))
        #expect(LyricsStore.state(from: .init(duration: 200, instrumental: false, plainLyrics: "words", syncedLyrics: nil)) == .unsynced)
        #expect(LyricsStore.state(from: .init(duration: 200, instrumental: true, plainLyrics: nil, syncedLyrics: nil)) == .instrumental)
        #expect(LyricsStore.state(from: .init(duration: nil, instrumental: nil, plainLyrics: nil, syncedLyrics: nil)) == .notFound)
    }

    @Test func lyricsOffByDefaultAndCollapsedShapeGrows() {
        let name = "NotchDeckLyrics.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        #expect(!SettingsStore(defaults: defaults).lyricsEnabled)
        let base = NotchShapeMetrics(bodySize: CGSize(width: 253, height: 32), earRadius: 4, bottomRadius: 8)
        let grown = NotchRootView.metrics(base, lyrics: true)
        // One line taller, never wider than the collapsed notch.
        #expect(grown.bodySize == CGSize(width: 253, height: 32 + NotchRootView.lyricsStripHeight))
        #expect(NotchRootView.metrics(base, lyrics: false) == base)
    }
}

// MARK: World clock

struct WorldClockTests {
    private let date = ISO8601DateFormatter().date(from: "2026-11-26T22:30:00Z")!   // 2:30 PM in Los Angeles

    @Test func relativeDayAndOffset() {
        let la = TimeZone(identifier: "America/Los_Angeles")!
        let ny = WorldClockCity(name: "New York", timeZoneID: "America/New_York")
        let tokyo = WorldClockCity(name: "Tokyo", timeZoneID: "Asia/Tokyo")
        let mumbai = WorldClockCity(name: "Mumbai", timeZoneID: "Asia/Kolkata")
        let here = WorldClockCity(name: "Los Angeles", timeZoneID: "America/Los_Angeles")
        #expect(ny.relativeDescription(at: date, local: la) == "Today, +3HRS")
        #expect(tokyo.relativeDescription(at: date, local: la) == "Tomorrow, +17HRS")
        #expect(mumbai.relativeDescription(at: date, local: la) == "Tomorrow, +13½HRS")
        #expect(here.relativeDescription(at: date, local: la) == "Today")
        #expect(here.isDaytime(at: date))
        #expect(tokyo.isDaytime(at: date))                                              // 7:30 AM there
        #expect(!WorldClockCity(name: "London", timeZoneID: "Europe/London").isDaytime(at: date))  // 10:30 PM there
    }

    @Test func catalogSearch() {
        #expect(CityCatalog.search("san fran").first?.timeZoneID == "America/Los_Angeles")
        #expect(CityCatalog.search("seoul").first?.timeZoneID == "Asia/Seoul")
        #expect(CityCatalog.search("sao paulo").first?.name == "Sao Paulo")   // diacritic-insensitive
        #expect(CityCatalog.cityName(for: "America/Argentina/Buenos_Aires") == "Buenos Aires")
        #expect(CityCatalog.search("").isEmpty)
        #expect(!CityCatalog.defaults.isEmpty)
    }

    @Test func citiesPersist() {
        let name = "NotchDeckClock.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let settings = SettingsStore(defaults: defaults)
        #expect(settings.worldClockCities == CityCatalog.defaults)
        settings.worldClockCities = [WorldClockCity(name: "Seoul", timeZoneID: "Asia/Seoul")]
        #expect(SettingsStore(defaults: defaults).worldClockCities.map(\.name) == ["Seoul"])
    }
}

// MARK: Terminal

@Suite(.serialized)
struct TerminalSessionTests {
    @Test func environmentIsATerminal() {
        let env = Dictionary(uniqueKeysWithValues: TerminalSession.environment().compactMap { line -> (String, String)? in
            guard let eq = line.firstIndex(of: "=") else { return nil }
            return (String(line[..<eq]), String(line[line.index(after: eq)...]))
        })
        #expect(env["TERM"] == "xterm-256color")
        #expect(env["COLORTERM"] == "truecolor")
        #expect(env["HOME"] == FileManager.default.homeDirectoryForCurrentUser.path)
        #expect(env["LANG"] != nil)
        #expect(TerminalModuleView.abbreviate(FileManager.default.homeDirectoryForCurrentUser.path + "/Developer") == "~/Developer")
    }

    /// A real PTY session: the login shell starts, runs what's typed, and `exit` ends it.
    @Test func shellRunsAndExits() async throws {
        let session = TerminalSession()
        let view = session.terminalView()
        #expect(session.isRunning)
        view.send(txt: "echo notchdeck-$((40+2))\r")
        func screen() -> String { String(decoding: view.getTerminal().getBufferAsData(), as: UTF8.self) }
        for _ in 0..<100 where !screen().contains("notchdeck-42") { try await Task.sleep(for: .milliseconds(50)) }
        #expect(screen().contains("notchdeck-42"))
        view.send(txt: "exit 7\r")
        for _ in 0..<100 where session.isRunning { try await Task.sleep(for: .milliseconds(50)) }
        #expect(!session.isRunning)
        #expect(session.exitCode == 7)

        session.restart()
        #expect(session.isRunning)
        session.terminalView().send(txt: "exit\r")   // restart gives a fresh terminal view
        for _ in 0..<100 where session.isRunning { try await Task.sleep(for: .milliseconds(50)) }
        #expect(!session.isRunning)
    }

    /// New Session ends the old shell and starts a fresh one; the old shell's late exit report must
    /// not mark the new session as stopped.
    @Test func newSessionReplacesTheShell() async throws {
        let session = TerminalSession()
        let first = session.terminalView()
        let firstPID = first.process.shellPid
        #expect(session.generation == 0)
        session.newSession()
        let second = session.terminalView()
        #expect(second !== first)
        #expect(session.generation == 1)
        #expect(session.isRunning)
        try await Task.sleep(for: .milliseconds(500))     // the old shell's exit arrives meanwhile
        #expect(session.isRunning)
        #expect(kill(firstPID, 0) != 0)                     // old shell is gone
        second.send(txt: "echo fresh-$((1+1))\r")
        func screen() -> String { String(decoding: second.getTerminal().getBufferAsData(), as: UTF8.self) }
        for _ in 0..<100 where !screen().contains("fresh-2") { try await Task.sleep(for: .milliseconds(50)) }
        #expect(screen().contains("fresh-2"))
        second.send(txt: "exit\r")
        for _ in 0..<100 where session.isRunning { try await Task.sleep(for: .milliseconds(50)) }
        #expect(!session.isRunning)
        #expect(TerminalSession.decodeExitStatus(7 << 8) == 7)
        #expect(TerminalSession.decodeExitStatus(0) == 0)
    }

    @Test func fontSizeIsClamped() {
        let session = TerminalSession()
        let view = session.terminalView()
        session.setFontSize(100)
        #expect(view.font.pointSize == TerminalSession.fontSizes.upperBound)
        session.setFontSize(1)
        #expect(view.font.pointSize == TerminalSession.fontSizes.lowerBound)
        view.send(txt: "exit\r")
    }
}

struct ClaudePlanAndPreferencesTests {
    static let claudeJSON = Data(#"""
    {"cachedUsageUtilization":{"fetchedAtMs":1795723499477,"accountUuid":"x","utilization":{
      "five_hour":{"utilization":19,"resets_at":"2026-11-27T00:50:00.394985+00:00","limit_dollars":null},
      "seven_day":{"utilization":42.5,"resets_at":"2026-11-30T01:00:00.395003+00:00"},
      "seven_day_opus":null,
      "tangelo":{"utilization":99},
      "extra_usage":{"is_enabled":false}}},
     "mcpServers":{}}
    """#.utf8)

    @Test func parsesClaudeCodesCachedPlanUsage() throws {
        let plan = try #require(ClaudePlanStatus.parse(claudeJSON: Self.claudeJSON))
        #expect(plan.windows.map(\.key) == ["five_hour", "seven_day"])          // internal / null windows skipped
        #expect(plan.windows[0].usedPercent == 19)
        #expect(plan.windows[1].usedPercent == 42.5)
        #expect(plan.windows[0].resetsAt == ISO8601DateFormatter().date(from: "2026-11-27T00:50:00Z"))
        #expect(plan.windows[0].label == "5-hour session")
        #expect(plan.fetchedAt == Date(timeIntervalSince1970: 1_795_723_499.477))
        let afterReset = ISO8601DateFormatter().date(from: "2026-11-27T01:00:00Z")!
        #expect(plan.windows[0].hasReset(at: afterReset))
        #expect(!plan.windows[1].hasReset(at: afterReset))
        #expect(ClaudePlanStatus.parse(claudeJSON: Data("{}".utf8)) == nil)
        #expect(ClaudePlanStatus.parse(claudeJSON: nil) == nil)
    }

    @Test func preferencesDefaultsPersistAndTolerateOldData() throws {
        let name = "NotchDeckUsagePrefs.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let settings = SettingsStore(defaults: defaults)
        #expect(settings.usagePreferences == UsagePreferences())
        #expect(settings.usagePreferences.shows(.claudeCode) && settings.usagePreferences.shows(.planLimits))
        settings.usagePreferences.sources.remove(.aiChat)
        settings.usagePreferences.stripItems = [.planLimits]
        settings.usagePreferences.defaultRange = "week"
        let reloaded = SettingsStore(defaults: defaults).usagePreferences
        #expect(!reloaded.shows(.aiChat))
        #expect(reloaded.strip(.planLimits) && !reloaded.strip(.todayTotals))
        #expect(reloaded.defaultRange == "week")
        // Data saved by an older version (missing fields) keeps the defaults for what's missing.
        let old = try JSONDecoder().decode(UsagePreferences.self, from: Data(#"{"sources":["codex"]}"#.utf8))
        #expect(old.sources == [.codex])
        #expect(old.sections == Set(UsageSection.allCases))
        #expect(old.showsAgentStrip)
    }

    @Test func hiddenSourcesLeaveTheModelBreakdown() throws {
        let name = "NotchDeckUsageHidden.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let settings = SettingsStore(defaults: defaults)
        let support = FileManager.default.temporaryDirectory.appending(path: "NDUsageHidden-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: support) }
        let store = UsageStore(settings: settings, directory: support, home: support)
        store.recordChat(model: "claude-opus-5-5", provider: .anthropic, tokens: TokenCounts(input: 10, output: 10))
        #expect(store.modelTotals(in: .today).count == 1)
        settings.usagePreferences.sources.remove(.aiChat)
        #expect(store.modelTotals(in: .today).isEmpty)
    }
}

struct ClaudeLivePlanTests {
    static let snapshot: [String: Any] = [
        "model": ["display_name": "Opus"],
        "rate_limits": [
            "five_hour": ["used_percentage": 85.4, "resets_at": 1_800_000_000],
            "seven_day": ["used_percentage": 38.0, "resets_at": 1_800_400_000],
        ],
    ]

    @Test func parsesStatusLineRateLimits() throws {
        let now = Date(timeIntervalSince1970: 1_799_990_000)
        let plan = try #require(ClaudePlanStatus.parse(statusLine: Self.snapshot, at: now))
        #expect(plan.isLive)
        #expect(plan.windows.map(\.key) == ["five_hour", "seven_day"])
        #expect(plan.windows.map(\.usedPercent) == [85.4, 38.0])
        #expect(plan.windows[0].resetsAt == Date(timeIntervalSince1970: 1_800_000_000))
        #expect(plan.fetchedAt == now)
        #expect(ClaudePlanStatus.parse(statusLine: ["model": [:] as [String: Any]]) == nil)   // API users / before 1st reply
    }

    @Test func liveDataIsNotReplacedByAnOlderSavedCopy() async throws {
        let home = FileManager.default.temporaryDirectory.appending(path: "NDLive-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: home) }
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try ClaudePlanAndPreferencesTests.claudeJSON.write(to: home.appending(path: ".claude.json"))   // saved copy: 19 %
        let name = "NotchDeckLive.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let store = UsageStore(settings: SettingsStore(defaults: defaults), directory: home.appending(path: "support"), home: home)
        await store.refresh()
        #expect(store.claudePlan?.windows.first?.usedPercent == 19)
        #expect(store.claudePlan?.isLive == false)
        store.updateClaudeStatusLine(Self.snapshot)          // live: 85 %
        await store.refresh()                                // the older saved copy must not win
        #expect(store.claudePlan?.windows.first?.usedPercent == 85.4)
        #expect(store.claudePlan?.isLive == true)
    }

    private func runScript(_ url: URL, input: [String: Any]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [url.path]
        let stdin = Pipe(), stdout = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        try process.run()
        stdin.fileHandleForWriting.write(try JSONSerialization.data(withJSONObject: input))
        try stdin.fileHandleForWriting.close()
        process.waitUntilExit()
        return String(decoding: stdout.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    @Test func installsRunsAndUninstallsTheStatusLine() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "NDStatusLine-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let settingsURL = dir.appending(path: "claude/settings.json")
        let scriptURL = dir.appending(path: "support/claude-statusline.sh")
        try FileManager.default.createDirectory(at: settingsURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(#"{"model":"opus","hooks":{}}"#.utf8).write(to: settingsURL)

        try ClaudeStatusLineInstaller.install(settingsURL: settingsURL, scriptURL: scriptURL, port: 1, token: "tok'en")
        #expect(ClaudeStatusLineInstaller.status(at: settingsURL) == .installed)
        let settings = try AgentHookInstaller.readSettings(at: settingsURL)
        #expect(settings["model"] as? String == "opus")                                  // other keys kept
        #expect((settings["statusLine"] as? [String: Any])?["command"] as? String == "\"\(scriptURL.path)\"")
        let attributes = try FileManager.default.attributesOfItem(atPath: scriptURL.path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o700)          // holds the token
        // Port 1 has no server: the forward fails silently and the status line still prints.
        #expect(try runScript(scriptURL, input: Self.snapshot) == "Session 85% · Week 38%")
        #expect(try runScript(scriptURL, input: ["model": [:] as [String: Any]]) == "")

        try ClaudeStatusLineInstaller.uninstall(settingsURL: settingsURL, scriptURL: scriptURL)
        #expect(ClaudeStatusLineInstaller.status(at: settingsURL) == .notInstalled)
        #expect(!FileManager.default.fileExists(atPath: scriptURL.path))
    }

    @Test func wrapsAndRestoresAnExistingStatusLine() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "NDStatusLine-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let settingsURL = dir.appending(path: "claude/settings.json")
        let scriptURL = dir.appending(path: "support/claude-statusline.sh")
        try FileManager.default.createDirectory(at: settingsURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(#"{"statusLine":{"type":"command","command":"echo 'my line'"}}"#.utf8).write(to: settingsURL)
        #expect(ClaudeStatusLineInstaller.status(at: settingsURL) == .otherStatusLine)

        try ClaudeStatusLineInstaller.install(settingsURL: settingsURL, scriptURL: scriptURL, port: 1, token: "t")
        #expect(try runScript(scriptURL, input: Self.snapshot) == "my line")              // yours keeps showing
        try ClaudeStatusLineInstaller.install(settingsURL: settingsURL, scriptURL: scriptURL, port: 2, token: "t")   // reinstall
        #expect(try runScript(scriptURL, input: Self.snapshot) == "my line")

        try ClaudeStatusLineInstaller.uninstall(settingsURL: settingsURL, scriptURL: scriptURL)
        let restored = try AgentHookInstaller.readSettings(at: settingsURL)["statusLine"] as? [String: Any]
        #expect(restored?["command"] as? String == "echo 'my line'")
    }
}

struct VisualizerAnimationTests {
    /// The keyframe loop must join up seamlessly: the level at the end of a loop equals the start.
    @Test func barsLoopSeamlessly() {
        for index in 0..<6 {
            let start = VisualizerLayerView.barLevel(index: index, time: 0)
            let end = VisualizerLayerView.barLevel(index: index, time: VisualizerLayerView.barLoop)
            #expect(abs(start - end) < 1e-9)
            for step in 0..<60 {
                let level = VisualizerLayerView.barLevel(index: index, time: Double(step) * 0.1)
                #expect((0.2...1.0).contains(level))
            }
        }
    }

    @Test func wavePathsHaveMatchingShapes() {
        // Keyframed paths must have the same number of points to interpolate.
        let size = CGSize(width: 16, height: 14)
        let a = VisualizerLayerView.wavePath(size: size, phase: 0, amplitude: 5)
        let b = VisualizerLayerView.wavePath(size: size, phase: 1, amplitude: 5)
        func points(_ path: CGPath) -> Int { var n = 0; path.applyWithBlock { _ in n += 1 }; return n }
        #expect(points(a) == points(b))
        #expect(points(a) >= 9)
    }

    @Test func viewAnimatesOnlyWhilePlaying() {
        let view = VisualizerLayerView(frame: NSRect(x: 0, y: 0, width: 16, height: 14))
        view.configure(style: .bars, barCount: 4, colors: [NSColor.red.cgColor], isPlaying: true)
        view.layout()
        let bars = view.layer?.sublayers ?? []
        #expect(bars.count == 4)
        #expect(bars.allSatisfy { $0.animation(forKey: "level") != nil })
        view.configure(style: .bars, barCount: 4, colors: [NSColor.red.cgColor], isPlaying: false)
        #expect(bars.allSatisfy { $0.animation(forKey: "level") == nil })
        view.configure(style: .wave, barCount: 4, colors: [NSColor.red.cgColor], isPlaying: true)
        view.layout()
        #expect(view.layer?.sublayers?.count == 1)
        #expect(view.layer?.sublayers?.first?.mask?.animation(forKey: "wave") != nil)
    }
}

struct MonitorAccentTests {
    @Test func systemMonitorColorDefaultsToBlueAndPersists() {
        let name = "NotchDeckMonitorAccent.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let settings = SettingsStore(defaults: defaults)
        #expect(settings.systemMonitorAccent == .blue)
        settings.systemMonitorAccent = .amber
        #expect(SettingsStore(defaults: defaults).systemMonitorAccent == .amber)
        settings.systemMonitorAccent = .artwork          // not offered for the System tab
        #expect(settings.systemMonitorAccent == .blue)
    }
}

struct MirrorDeactivationTests {
    /// Switching away from Mirror turns the camera off at once; doing it when nothing runs is harmless.
    @Test func deactivateIsImmediateAndSafe() {
        let mirror = CameraMirrorStore()
        mirror.deactivate()
        #expect(!mirror.isRunning)
        mirror.session.cancelPendingStart()
        mirror.deactivate()
        #expect(!mirror.isRunning)
    }
}

struct Phase7LayoutTests {
    @Test func layoutsAndAvailability() {
        #expect(ExpandedLayout.forModule(.usage, hasPendingApproval: false) == .tall)
        #expect(ExpandedLayout.forModule(.commandRunner, hasPendingApproval: false) == .tall)
        #expect(ExpandedLayout.forModule(.worldClock, hasPendingApproval: false, fittedHeight: 150) == .fitted(150))
        #expect(NotchModule.worldClock.isAvailable && NotchModule.usage.isAvailable && NotchModule.commandRunner.isAvailable)
        // New modules are appended (enabled) to an older saved tab order.
        let reconciled = ModuleConfiguration.reconciled([ModuleConfiguration(module: .media, isEnabled: true)])
        #expect(reconciled.last?.module == .commandRunner)
        let allEnabled = reconciled.allSatisfy { $0.isEnabled }
        #expect(allEnabled)
    }
}
