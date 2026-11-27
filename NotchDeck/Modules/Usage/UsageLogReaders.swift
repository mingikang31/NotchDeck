import Foundation

/// Where a usage record came from.
nonisolated enum UsageSource: String, Codable, CaseIterable, Identifiable, Sendable {
    case aiChat, claudeCode, codex

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .aiChat: "AI Chat"
        case .claudeCode: "Claude Code"
        case .codex: "Codex"
        }
    }

    var symbol: String {
        switch self {
        case .aiChat: "sparkles"
        case .claudeCode: "terminal.fill"
        case .codex: "chevron.left.forwardslash.chevron.right"
        }
    }

    /// AI Chat uses the user's own API keys (real per-token cost); the coding agents may be on a
    /// subscription, so their cost is an API-price estimate.
    var costIsEstimate: Bool { self != .aiChat }
}

/// One billed request.
nonisolated struct UsageRecord: Codable, Equatable, Identifiable, Sendable {
    var id: String
    var source: UsageSource
    var date: Date
    var model: String
    var tokens: TokenCounts
    /// Fast mode (2×) and US-only inference (1.1×) price multipliers.
    var priceMultiplier: Double = 1
    var sessionID: String?
    var project: String?
}

/// Claude Code's plan limit as last reported in its transcript (`quotaLimits`).
nonisolated struct ClaudeLimitStatus: Equatable, Sendable {
    var status: String          // "allowed", "allowed_warning", "rejected"
    var resetsAt: Date?
    var kind: String?           // "five_hour", "seven_day", …
    var reportedAt: Date

    var kindDescription: String {
        switch kind {
        case "five_hour": "5-hour limit"
        case "seven_day": "weekly limit"
        case "seven_day_opus": "weekly Opus limit"
        default: kind.map { $0.replacingOccurrences(of: "_", with: " ") } ?? "usage limit"
        }
    }
}

/// Codex's plan usage as last reported (`rate_limits` on token_count events).
nonisolated struct CodexPlanStatus: Equatable, Sendable {
    struct Window: Equatable, Sendable {
        var usedPercent: Double
        var minutes: Int?
        var resetsAt: Date?

        var description: String {
            guard let minutes else { return "window" }
            switch minutes {
            case 300: return "5-hour window"
            case 10_080: return "weekly window"
            case 43_200: return "30-day window"
            default: return minutes % 1440 == 0 ? "\(minutes / 1440)-day window" : "\(minutes / 60)-hour window"
            }
        }
    }

    var plan: String?
    var primary: Window?
    var secondary: Window?
    var reportedAt: Date
}

// MARK: - Claude Code transcripts

/// Reads `~/.claude/projects/**/*.jsonl`. Each assistant message line carries `message.usage`;
/// one message is written once per content block, so records are de-duplicated by message + request ID.
nonisolated enum ClaudeCodeLog {
    struct Entry: Equatable, Sendable {
        var record: UsageRecord
        /// MCP servers whose tools this message called (`mcp__<server>__<tool>`).
        var mcpServers: [String]
    }

    static func parseDate(_ value: Any?) -> Date? {
        guard let string = value as? String else { return nil }
        return fastISODate(string) ?? isoFractional.date(from: string) ?? isoPlain.date(from: string)
    }

    /// `2026-11-26T10:00:00.123Z` without a date formatter (formatters dominated scan time).
    static func fastISODate(_ string: String) -> Date? {
        let bytes = Array(string.utf8)
        guard bytes.count >= 20, bytes[4] == 0x2D, bytes[7] == 0x2D, bytes[10] == 0x54, bytes[13] == 0x3A, bytes[16] == 0x3A,
              bytes.last == 0x5A else { return nil }
        func number(_ range: Range<Int>) -> Int? {
            var value = 0
            for index in range {
                let digit = Int(bytes[index]) - 48
                guard (0...9).contains(digit) else { return nil }
                value = value * 10 + digit
            }
            return value
        }
        guard let year = number(0..<4), let month = number(5..<7), let day = number(8..<10),
              let hour = number(11..<13), let minute = number(14..<16), let second = number(17..<19),
              (1...12).contains(month), (1...31).contains(day) else { return nil }
        var fraction = 0.0
        if bytes.count > 21, bytes[19] == 0x2E {
            var scale = 0.1
            for index in 20..<(bytes.count - 1) {
                let digit = Int(bytes[index]) - 48
                guard (0...9).contains(digit) else { return nil }
                fraction += Double(digit) * scale
                scale /= 10
            }
        } else if bytes.count != 20 {
            return nil
        }
        // Days from civil (Howard Hinnant's algorithm), UTC.
        let y = month <= 2 ? year - 1 : year
        let era = (y >= 0 ? y : y - 399) / 400
        let yoe = y - era * 400
        let doy = (153 * (month + (month > 2 ? -3 : 9)) + 2) / 5 + day - 1
        let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
        let days = era * 146_097 + doe - 719_468
        return Date(timeIntervalSince1970: Double(days * 86_400 + hour * 3600 + minute * 60 + second) + fraction)
    }

    nonisolated(unsafe) private static let isoFractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
    nonisolated(unsafe) private static let isoPlain = ISO8601DateFormatter()

    /// Cheap pre-filter so request / attachment / user lines (which can quote assistant messages)
    /// are never JSON-decoded: an assistant line has a top-level `"type":"assistant"` and usage.
    static func mightContainUsage(_ line: Data) -> Bool {
        line.range(of: typeAssistant) != nil && line.range(of: usageKey) != nil
    }

    private static let typeAssistant = Data(#""type":"assistant""#.utf8)
    private static let usageKey = Data(#""output_tokens""#.utf8)

    static func entry(from line: Data) -> Entry? {
        guard mightContainUsage(line),
              let json = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              json["type"] as? String == "assistant",
              let message = json["message"] as? [String: Any],
              let usage = message["usage"] as? [String: Any],
              let model = message["model"] as? String, !model.hasPrefix("<"),
              let date = parseDate(json["timestamp"]) else { return nil }

        func int(_ key: String, in dict: [String: Any] = usage) -> Int { (dict[key] as? NSNumber)?.intValue ?? 0 }
        var tokens = TokenCounts(input: int("input_tokens"), cacheRead: int("cache_read_input_tokens"), output: int("output_tokens"))
        if let creation = usage["cache_creation"] as? [String: Any] {
            tokens.cacheWrite5m = int("ephemeral_5m_input_tokens", in: creation)
            tokens.cacheWrite1h = int("ephemeral_1h_input_tokens", in: creation)
        } else {
            tokens.cacheWrite5m = int("cache_creation_input_tokens")
        }
        guard !tokens.isEmpty else { return nil }

        var multiplier = 1.0
        if usage["speed"] as? String == "fast" { multiplier *= 2 }
        if usage["inference_geo"] as? String == "us" { multiplier *= 1.1 }

        let messageID = message["id"] as? String ?? UUID().uuidString
        let requestID = json["requestId"] as? String ?? ""
        let cwd = json["cwd"] as? String
        let servers = (message["content"] as? [[String: Any]] ?? []).compactMap { block -> String? in
            guard block["type"] as? String == "tool_use", let name = block["name"] as? String, name.hasPrefix("mcp__") else { return nil }
            let parts = name.components(separatedBy: "__")
            return parts.count >= 3 ? parts[1] : nil
        }
        return Entry(
            record: UsageRecord(
                id: "cc:\(messageID):\(requestID)", source: .claudeCode, date: date, model: model, tokens: tokens,
                priceMultiplier: multiplier, sessionID: json["sessionId"] as? String,
                project: cwd.map { ($0 as NSString).lastPathComponent }
            ),
            mcpServers: servers
        )
    }

    static func limitStatus(from line: Data) -> ClaudeLimitStatus? {
        guard line.range(of: Data(#""quotaLimits""#.utf8)) != nil,
              let json = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              let quota = json["quotaLimits"] as? [String: Any],
              let status = quota["status"] as? String else { return nil }
        return ClaudeLimitStatus(
            status: status,
            resetsAt: (quota["resetsAt"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue) },
            kind: quota["rateLimitType"] as? String,
            reportedAt: parseDate(json["timestamp"]) ?? Date()
        )
    }
}

// MARK: - Codex session logs

/// Reads `~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl`. `token_count` events carry the turn's
/// usage (`last_token_usage`) and a running total; a turn is counted when the total grows.
/// OpenAI reports cached tokens *inside* `input_tokens`, so they're split out here.
nonisolated enum CodexLog {
    /// Per-file parsing state, kept between incremental reads.
    struct FileState: Sendable {
        var model = "codex"
        var sessionID: String?
        var project: String?
        var lastTotal = 0
        var turn = 0
    }

    static func tokens(from usage: [String: Any]) -> TokenCounts {
        func int(_ key: String) -> Int { (usage[key] as? NSNumber)?.intValue ?? 0 }
        let cached = int("cached_input_tokens")
        return TokenCounts(
            input: max(0, int("input_tokens") - cached),
            cacheWrite5m: int("cache_write_input_tokens"),
            cacheRead: cached,
            output: int("output_tokens")
        )
    }

    /// Updates `state`; returns a record for a counted turn and/or the plan status, if the line has them.
    static func process(_ line: Data, state: inout FileState, fileID: String) -> (record: UsageRecord?, plan: CodexPlanStatus?) {
        let interesting = [#""token_count""#, #""turn_context""#, #""session_meta""#]
        guard interesting.contains(where: { line.range(of: Data($0.utf8)) != nil }),
              let json = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              let payload = json["payload"] as? [String: Any] else { return (nil, nil) }
        let date = ClaudeCodeLog.parseDate(json["timestamp"]) ?? Date()

        switch json["type"] as? String {
        case "session_meta":
            state.sessionID = payload["id"] as? String ?? payload["session_id"] as? String
            state.project = (payload["cwd"] as? String).map { ($0 as NSString).lastPathComponent }
            return (nil, nil)
        case "turn_context":
            if let model = payload["model"] as? String { state.model = model }
            return (nil, nil)
        case "event_msg" where payload["type"] as? String == "token_count":
            var record: UsageRecord?
            if let info = payload["info"] as? [String: Any],
               let total = (info["total_token_usage"] as? [String: Any])?["total_tokens"] as? NSNumber,
               total.intValue > state.lastTotal,
               let last = info["last_token_usage"] as? [String: Any] {
                state.lastTotal = total.intValue
                state.turn += 1
                let tokens = tokens(from: last)
                if !tokens.isEmpty {
                    record = UsageRecord(id: "cx:\(fileID):\(state.turn)", source: .codex, date: date, model: state.model,
                                         tokens: tokens, sessionID: state.sessionID, project: state.project)
                }
            }
            return (record, plan(from: payload["rate_limits"] as? [String: Any], date: date))
        default:
            return (nil, nil)
        }
    }

    static func plan(from limits: [String: Any]?, date: Date) -> CodexPlanStatus? {
        guard let limits else { return nil }
        func window(_ key: String) -> CodexPlanStatus.Window? {
            guard let w = limits[key] as? [String: Any], let used = (w["used_percent"] as? NSNumber)?.doubleValue else { return nil }
            return .init(usedPercent: used,
                         minutes: (w["window_minutes"] as? NSNumber)?.intValue,
                         resetsAt: (w["resets_at"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue) })
        }
        return CodexPlanStatus(plan: limits["plan_type"] as? String, primary: window("primary"), secondary: window("secondary"), reportedAt: date)
    }
}

// MARK: - MCP servers

/// An MCP server configured for Claude Code or Codex.
nonisolated struct MCPServerInfo: Identifiable, Equatable, Sendable {
    var name: String
    var agent: UsageSource
    /// "user", "project: <name>", or a config file name.
    var scope: String
    var transport: String
    /// Last time the active Claude Code session called one of its tools.
    var lastUsed: Date?

    var id: String { "\(agent.rawValue):\(scope):\(name)" }
}

nonisolated enum MCPConfigReader {
    /// `~/.claude.json` (user + per-project servers) and `<project>/.mcp.json`.
    static func claudeServers(claudeJSON: Data?, projectDirectories: [String], fileManager: FileManager = .default) -> [MCPServerInfo] {
        var servers: [MCPServerInfo] = []
        func add(_ dict: [String: Any]?, scope: String) {
            for (name, value) in dict ?? [:] {
                let config = value as? [String: Any] ?? [:]
                let transport = config["type"] as? String ?? (config["url"] != nil ? "http" : "stdio")
                servers.append(MCPServerInfo(name: name, agent: .claudeCode, scope: scope, transport: transport))
            }
        }
        if let data = claudeJSON, let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            add(json["mcpServers"] as? [String: Any], scope: "user")
            for (path, project) in json["projects"] as? [String: Any] ?? [:] where projectDirectories.contains(path) {
                add((project as? [String: Any])?["mcpServers"] as? [String: Any], scope: "project: \((path as NSString).lastPathComponent)")
            }
        }
        for directory in projectDirectories {
            let url = URL(fileURLWithPath: directory).appending(path: ".mcp.json")
            if let data = fileManager.contents(atPath: url.path),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                add(json["mcpServers"] as? [String: Any], scope: ".mcp.json: \((directory as NSString).lastPathComponent)")
            }
        }
        return servers.sorted { $0.name < $1.name }
    }

    /// `[mcp_servers.NAME]` tables in `~/.codex/config.toml` (sub-tables like `.env` are skipped).
    static func codexServers(configTOML: String?) -> [MCPServerInfo] {
        guard let text = configTOML else { return [] }
        var servers: [MCPServerInfo] = []
        var current: (name: String, transport: String)?
        func flush() {
            if let current { servers.append(MCPServerInfo(name: current.name, agent: .codex, scope: "user", transport: current.transport)) }
            current = nil
        }
        for rawLine in text.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[") {
                let header = line.trimmingCharacters(in: CharacterSet(charactersIn: "[] "))
                if header.hasPrefix("mcp_servers.") {
                    let name = String(header.dropFirst("mcp_servers.".count)).trimmingCharacters(in: CharacterSet(charactersIn: "\""))
                    if name.contains(".") { continue }  // sub-table of the current server
                    flush()
                    current = (name, "stdio")
                } else {
                    flush()
                }
            } else if line.hasPrefix("url"), current != nil {
                current?.transport = "http"
            }
        }
        flush()
        return servers.sorted { $0.name < $1.name }
    }
}
