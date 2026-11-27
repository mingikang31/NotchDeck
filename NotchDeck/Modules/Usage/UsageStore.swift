import Foundation
import Observation
import OSLog

/// Reads Claude Code / Codex logs incrementally, off the main thread. Remembers how far each file
/// was read, so a refresh only parses lines added since the last one.
actor UsageScanner {
    struct Result: Sendable {
        var newRecords: [UsageRecord] = []
        var claudeLimit: ClaudeLimitStatus?
        var codexPlan: CodexPlanStatus?
        /// sessionID → (MCP server → last call).
        var mcpUse: [String: [String: Date]] = [:]
        /// Working directories of recent Claude Code sessions (for project-scoped MCP configs).
        var recentProjectDirectories: [String] = []
        var mcpServers: [MCPServerInfo] = []
    }

    static let lookback: TimeInterval = 31 * 24 * 3600

    private let claudeRoot: URL
    private let codexRoot: URL
    private let claudeJSON: URL
    private let codexConfig: URL
    private var offsets: [String: UInt64] = [:]
    private var codexStates: [String: CodexLog.FileState] = [:]
    private var seen: Set<String> = []
    private var claudeLimit: ClaudeLimitStatus?
    private var codexPlan: CodexPlanStatus?
    private var mcpUse: [String: [String: Date]] = [:]
    private var sessionDirectories: [String: (path: String, date: Date)] = [:]

    init(home: URL) {
        claudeRoot = home.appending(path: ".claude/projects", directoryHint: .isDirectory)
        codexRoot = home.appending(path: ".codex/sessions", directoryHint: .isDirectory)
        claudeJSON = home.appending(path: ".claude.json")
        codexConfig = home.appending(path: ".codex/config.toml")
    }

    func scan(now: Date = Date()) -> Result {
        var result = Result()
        let cutoff = now.addingTimeInterval(-Self.lookback)

        for file in Self.jsonlFiles(under: claudeRoot, modifiedAfter: cutoff) {
            for line in newLines(of: file) {
                if let entry = ClaudeCodeLog.entry(from: line) {
                    if let session = entry.record.sessionID {
                        for server in entry.mcpServers { mcpUse[session, default: [:]][server] = entry.record.date }
                    }
                    if seen.insert(entry.record.id).inserted, entry.record.date >= cutoff {
                        result.newRecords.append(entry.record)
                    }
                    if let session = entry.record.sessionID, let cwd = Self.cwd(in: line) {
                        sessionDirectories[session] = (cwd, entry.record.date)
                    }
                } else if let limit = ClaudeCodeLog.limitStatus(from: line),
                          limit.reportedAt >= (claudeLimit?.reportedAt ?? .distantPast) {
                    claudeLimit = limit
                }
            }
        }

        for file in Self.jsonlFiles(under: codexRoot, modifiedAfter: cutoff) {
            let key = file.path
            var state = codexStates[key] ?? CodexLog.FileState()
            let fileID = file.deletingPathExtension().lastPathComponent
            for line in newLines(of: file) {
                let (record, plan) = CodexLog.process(line, state: &state, fileID: fileID)
                if let record, seen.insert(record.id).inserted, record.date >= cutoff { result.newRecords.append(record) }
                if let plan, plan.reportedAt >= (codexPlan?.reportedAt ?? .distantPast) { codexPlan = plan }
            }
            codexStates[key] = state
        }

        let recent = sessionDirectories.values.filter { now.timeIntervalSince($0.date) < 7 * 24 * 3600 }.map(\.path)
        result.recentProjectDirectories = Array(Set(recent))
        result.claudeLimit = claudeLimit
        result.codexPlan = codexPlan
        result.mcpUse = mcpUse
        result.mcpServers = MCPConfigReader.claudeServers(
            claudeJSON: FileManager.default.contents(atPath: claudeJSON.path),
            projectDirectories: result.recentProjectDirectories
        ) + MCPConfigReader.codexServers(configTOML: try? String(contentsOf: codexConfig, encoding: .utf8))
        return result
    }

    /// Complete lines appended since the last read (a partly written last line waits for next time).
    private func newLines(of file: URL) -> [Data] {
        let key = file.path
        guard let size = (try? FileManager.default.attributesOfItem(atPath: key)[.size] as? NSNumber)?.uint64Value else { return [] }
        var offset = offsets[key] ?? 0
        if size < offset { offset = 0 }       // rewritten / truncated
        guard size > offset, let handle = try? FileHandle(forReadingFrom: file) else { return [] }
        defer { try? handle.close() }
        try? handle.seek(toOffset: offset)
        guard let data = try? handle.readToEnd(), let lastNewline = data.lastIndex(of: 0x0A) else { return [] }
        offsets[key] = offset + UInt64(lastNewline - data.startIndex + 1)
        return data[data.startIndex..<lastNewline].split(separator: 0x0A, omittingEmptySubsequences: true).map { Data($0) }
    }

    private static func jsonlFiles(under root: URL, modifiedAfter cutoff: Date) -> [URL] {
        guard let enumerator = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey], options: [.skipsHiddenFiles]
        ) else { return [] }
        var files: [URL] = []
        for case let url as URL in enumerator where url.pathExtension == "jsonl" {
            let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .isRegularFileKey])
            if values?.isRegularFile == true, (values?.contentModificationDate ?? .distantPast) >= cutoff { files.append(url) }
        }
        return files
    }

    private static func cwd(in line: Data) -> String? {
        guard let range = line.range(of: Data(#""cwd":""#.utf8)) else { return nil }
        let rest = line[range.upperBound...]
        guard let end = rest.firstIndex(of: UInt8(ascii: "\"")) else { return nil }
        return String(data: rest[rest.startIndex..<end], encoding: .utf8)?.replacingOccurrences(of: "\\/", with: "/")
    }
}

/// Token usage and estimated cost across AI Chat, Claude Code and Codex, plus plan limits and
/// configured MCP servers. Logs are read only while a view showing usage is on screen.
@Observable
final class UsageStore {
    enum Range: String, CaseIterable, Identifiable {
        case today, week, month

        var id: String { rawValue }
        var displayName: String {
            switch self {
            case .today: "Today"
            case .week: "7 days"
            case .month: "30 days"
            }
        }

        func start(from now: Date, calendar: Calendar = .current) -> Date {
            switch self {
            case .today: calendar.startOfDay(for: now)
            case .week: calendar.startOfDay(for: now.addingTimeInterval(-6 * 86_400))
            case .month: calendar.startOfDay(for: now.addingTimeInterval(-29 * 86_400))
            }
        }
    }

    struct Totals: Equatable {
        var tokens = TokenCounts()
        var requests = 0
        var cost = 0.0
        /// Tokens from models with no known price (cost shows as incomplete).
        var unpricedTokens = 0

        var hasUnpriced: Bool { unpricedTokens > 0 }
    }

    struct ModelTotals: Identifiable, Equatable {
        var model: String
        var source: UsageSource
        var totals: Totals
        var id: String { "\(source.rawValue):\(model)" }
    }

    struct Session: Identifiable, Equatable {
        var source: UsageSource
        var sessionID: String
        var project: String?
        var model: String
        var totals: Totals
        var lastActivity: Date
        var mcpUsed: [String]
        var id: String { "\(source.rawValue):\(sessionID)" }
    }

    static let pollInterval: Duration = .seconds(15)
    static let chatRetention: TimeInterval = 90 * 86_400
    /// A session counts as active if it logged usage this recently.
    static let activeWindow: TimeInterval = 30 * 60

    private(set) var records: [UsageRecord] = []
    private(set) var claudeLimit: ClaudeLimitStatus?
    private(set) var codexPlan: CodexPlanStatus?
    private(set) var mcpServers: [MCPServerInfo] = []
    private(set) var mcpUse: [String: [String: Date]] = [:]
    private(set) var lastRefresh: Date?
    private(set) var isRefreshing = false
    var range: Range = .today

    @ObservationIgnored private let settings: SettingsStore
    @ObservationIgnored private let chatFile: URL
    @ObservationIgnored private let scanner: UsageScanner
    @ObservationIgnored private var chatRecords: [UsageRecord] = []
    @ObservationIgnored private var agentRecords: [UsageRecord] = []
    @ObservationIgnored private var visibleViews = 0
    @ObservationIgnored private var pollTask: Task<Void, Never>?
    @ObservationIgnored private let logger = Logger(subsystem: "com.notchdeck.NotchDeck", category: "Usage")
    /// Views ask for the same summaries on every redraw; they're computed once per data / price change.
    @ObservationIgnored private var priceCache: [String: ModelPrice?] = [:]
    @ObservationIgnored private var priceCacheRows: [ModelPrice] = []
    @ObservationIgnored private var totalsCache: [String: Totals] = [:]
    @ObservationIgnored private var modelTotalsCache: [String: [ModelTotals]] = [:]
    @ObservationIgnored private var sessionsCache: (key: String, sessions: [Session])?

    init(
        settings: SettingsStore,
        directory: URL = URL.applicationSupportDirectory.appending(path: "NotchDeck", directoryHint: .isDirectory),
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) {
        self.settings = settings
        chatFile = directory.appending(path: "usage-chat.json")
        scanner = UsageScanner(home: home)
        loadChat()
        publish()
    }

    // MARK: Recording (AI Chat)

    func recordChat(model: String, provider: ChatProvider, tokens: TokenCounts, date: Date = Date()) {
        guard !tokens.isEmpty else { return }
        chatRecords.append(UsageRecord(id: "chat:\(UUID().uuidString)", source: .aiChat, date: date, model: model, tokens: tokens,
                                       project: provider.rawValue))
        let cutoff = Date().addingTimeInterval(-Self.chatRetention)
        chatRecords.removeAll { $0.date < cutoff }
        saveChat()
        publish()
    }

    // MARK: Refreshing (Claude Code / Codex logs)

    func viewAppeared() {
        visibleViews += 1
        guard pollTask == nil else { return }
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                try? await Task.sleep(for: Self.pollInterval)
            }
        }
    }

    func viewDisappeared() {
        visibleViews = max(0, visibleViews - 1)
        guard visibleViews == 0 else { return }
        pollTask?.cancel()
        pollTask = nil
    }

    func refresh() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        let result = await scanner.scan()
        let cutoff = Date().addingTimeInterval(-UsageScanner.lookback)
        let before = agentRecords.count
        agentRecords.removeAll { $0.date < cutoff }
        let pruned = agentRecords.count != before
        agentRecords.append(contentsOf: result.newRecords)
        if claudeLimit != result.claudeLimit { claudeLimit = result.claudeLimit }
        if codexPlan != result.codexPlan { codexPlan = result.codexPlan }
        if mcpUse != result.mcpUse { mcpUse = result.mcpUse }
        if mcpServers != result.mcpServers { mcpServers = result.mcpServers }
        lastRefresh = Date()
        if pruned || !result.newRecords.isEmpty { publish() }
    }

    private func publish() {
        records = (chatRecords + agentRecords).sorted { $0.date < $1.date }
        invalidateSummaries()
    }

    private func invalidateSummaries() {
        totalsCache.removeAll()
        modelTotalsCache.removeAll()
        sessionsCache = nil
    }

    /// Cache key part that changes when the day (range start) or prices change.
    private func summaryKey(_ range: Range, now: Date) -> String {
        refreshPriceCacheIfNeeded()
        return "\(range.rawValue)|\(Int(range.start(from: now).timeIntervalSince1970))"
    }

    private func refreshPriceCacheIfNeeded() {
        let rows = settings.customModelPrices
        guard rows != priceCacheRows else { return }
        priceCacheRows = rows
        priceCache.removeAll()
        invalidateSummaries()
    }

    // MARK: Cost

    func price(for model: String) -> ModelPrice? {
        refreshPriceCacheIfNeeded()
        if let cached = priceCache[model] { return cached }
        let price = ModelPricing.price(for: model, custom: priceCacheRows)
        priceCache[model] = price
        return price
    }

    func cost(of record: UsageRecord) -> Double? {
        price(for: record.model)?.cost(of: record.tokens, multiplier: record.priceMultiplier)
    }

    // MARK: Summaries

    func totals(_ records: [UsageRecord]) -> Totals {
        var totals = Totals()
        for record in records {
            totals.tokens += record.tokens
            totals.requests += 1
            if let cost = cost(of: record) { totals.cost += cost } else { totals.unpricedTokens += record.tokens.total }
        }
        return totals
    }

    func records(in range: Range, now: Date = Date()) -> [UsageRecord] {
        let start = range.start(from: now)
        return records.filter { $0.date >= start }
    }

    func totals(for source: UsageSource, in range: Range, now: Date = Date()) -> Totals {
        let key = "\(source.rawValue)|" + summaryKey(range, now: now)
        if let cached = totalsCache[key] { return cached }
        let value = totals(records(in: range, now: now).filter { $0.source == source })
        totalsCache[key] = value
        return value
    }

    func modelTotals(in range: Range, now: Date = Date()) -> [ModelTotals] {
        let key = summaryKey(range, now: now)
        if let cached = modelTotalsCache[key] { return cached }
        let value = computeModelTotals(in: range, now: now)
        modelTotalsCache[key] = value
        return value
    }

    private func computeModelTotals(in range: Range, now: Date) -> [ModelTotals] {
        let groups = Dictionary(grouping: records(in: range, now: now)) { "\($0.source.rawValue)\u{1F}\($0.model)" }
        return groups.values.compactMap { group in
            guard let first = group.first else { return nil }
            return ModelTotals(model: first.model, source: first.source, totals: totals(group))
        }
        .sorted { $0.totals.tokens.total > $1.totals.tokens.total }
    }

    /// Claude Code / Codex sessions that logged usage in the last 30 minutes, newest first.
    func activeSessions(now: Date = Date()) -> [Session] {
        // Recomputed at most once a minute (activity ages out of the 30-minute window slowly).
        let key = "\(Int(now.timeIntervalSince1970 / 60))|\(summaryKey(.today, now: now))"
        if let cached = sessionsCache, cached.key == key { return cached.sessions }
        let sessions = computeActiveSessions(now: now)
        sessionsCache = (key, sessions)
        return sessions
    }

    private func computeActiveSessions(now: Date) -> [Session] {
        let recent = records.filter { $0.source != .aiChat && $0.sessionID != nil && now.timeIntervalSince($0.date) < 12 * 3600 }
        let groups = Dictionary(grouping: recent) { "\($0.source.rawValue):\($0.sessionID ?? "")" }
        return groups.values.compactMap { group -> Session? in
            guard let last = group.max(by: { $0.date < $1.date }), now.timeIntervalSince(last.date) < Self.activeWindow,
                  let sessionID = last.sessionID else { return nil }
            let servers = (mcpUse[sessionID] ?? [:]).sorted { $0.value > $1.value }.map(\.key)
            return Session(source: last.source, sessionID: sessionID, project: last.project, model: last.model,
                           totals: totals(group), lastActivity: last.date, mcpUsed: servers)
        }
        .sorted { $0.lastActivity > $1.lastActivity }
    }

    /// The Claude Code plan limit, if it's currently hit or close (not when it has already reset).
    func currentClaudeLimit(now: Date = Date()) -> ClaudeLimitStatus? {
        guard let limit = claudeLimit, limit.status != "allowed" else { return nil }
        if let reset = limit.resetsAt, reset <= now { return nil }
        return limit
    }

    // MARK: Persistence

    private func loadChat() {
        guard let data = try? Data(contentsOf: chatFile),
              let decoded = try? JSONDecoder().decode([UsageRecord].self, from: data) else { return }
        chatRecords = decoded
    }

    private func saveChat() {
        do {
            try FileManager.default.createDirectory(at: chatFile.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(chatRecords).write(to: chatFile, options: .atomic)
        } catch {
            logger.error("Couldn't save chat usage: \(error.localizedDescription, privacy: .public)")
        }
    }
}

/// Compact number formatting shared by the usage views.
enum UsageFormat {
    static func tokens(_ count: Int) -> String {
        switch count {
        case 1_000_000_000...: String(format: "%.1fB", Double(count) / 1e9)
        case 10_000_000...: String(format: "%.0fM", Double(count) / 1e6)
        case 1_000_000...: String(format: "%.1fM", Double(count) / 1e6)
        case 10_000...: String(format: "%.0fK", Double(count) / 1e3)
        case 1_000...: String(format: "%.1fK", Double(count) / 1e3)
        default: "\(count)"
        }
    }

    /// "$4.10", "<$0.01", "≈$12" for estimates; "—" when nothing could be priced.
    static func cost(_ totals: UsageStore.Totals, estimate: Bool) -> String {
        if totals.cost == 0 && totals.hasUnpriced { return "—" }
        let amount: String
        if totals.cost == 0 { amount = "$0" } else if totals.cost < 0.01 { amount = "<$0.01" } else if totals.cost < 100 {
            amount = String(format: "$%.2f", totals.cost)
        } else {
            amount = String(format: "$%.0f", totals.cost)
        }
        return (estimate ? "≈" : "") + amount + (totals.hasUnpriced ? "+" : "")
    }
}
