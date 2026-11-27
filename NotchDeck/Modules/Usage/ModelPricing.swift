import Foundation

/// Token counts for one request (or a sum of them), split the way prices are.
/// `input` is *uncached* input; providers that report cached tokens inside their input total
/// (OpenAI, Gemini) are converted when parsed.
nonisolated struct TokenCounts: Codable, Equatable, Sendable {
    var input = 0
    var cacheWrite5m = 0
    var cacheWrite1h = 0
    var cacheRead = 0
    /// Includes reasoning / thinking tokens (billed as output).
    var output = 0

    var total: Int { input + cacheWrite5m + cacheWrite1h + cacheRead + output }
    /// Everything that went in (what a model's long-prompt pricing tier is judged on).
    var promptTotal: Int { input + cacheWrite5m + cacheWrite1h + cacheRead }
    var isEmpty: Bool { total == 0 }

    static func + (a: TokenCounts, b: TokenCounts) -> TokenCounts {
        TokenCounts(
            input: a.input + b.input,
            cacheWrite5m: a.cacheWrite5m + b.cacheWrite5m,
            cacheWrite1h: a.cacheWrite1h + b.cacheWrite1h,
            cacheRead: a.cacheRead + b.cacheRead,
            output: a.output + b.output
        )
    }

    static func += (a: inout TokenCounts, b: TokenCounts) { a = a + b }

    /// Field-wise maximum: merges cumulative usage reports from one streamed reply.
    func merged(with other: TokenCounts) -> TokenCounts {
        TokenCounts(
            input: max(input, other.input),
            cacheWrite5m: max(cacheWrite5m, other.cacheWrite5m),
            cacheWrite1h: max(cacheWrite1h, other.cacheWrite1h),
            cacheRead: max(cacheRead, other.cacheRead),
            output: max(output, other.output)
        )
    }
}

/// Per-million-token prices (USD) for one model.
nonisolated struct ModelPrice: Codable, Equatable, Identifiable, Sendable {
    /// Model ID to match, e.g. `claude-opus-5-5`; a trailing `*` matches as a prefix (`gpt-5*`).
    var pattern: String
    var input: Double
    var output: Double
    var cacheWrite5m: Double
    var cacheWrite1h: Double
    var cacheRead: Double
    /// Prompts above this many tokens pay `longPromptMultiplier` × every price (Claude Haiku 5.5).
    var longPromptThreshold: Int?
    var longPromptMultiplier: Double?

    var id: String { pattern }

    /// A row with cache prices derived the standard way (writes 1.25× / 2×, reads given).
    static func row(_ pattern: String, _ input: Double, _ output: Double, cacheRead: Double? = nil) -> ModelPrice {
        ModelPrice(pattern: pattern, input: input, output: output,
                   cacheWrite5m: input * 1.25, cacheWrite1h: input * 2, cacheRead: cacheRead ?? input * 0.1)
    }

    func cost(of tokens: TokenCounts, multiplier: Double = 1) -> Double {
        var scale = multiplier
        if let threshold = longPromptThreshold, tokens.promptTotal > threshold { scale *= longPromptMultiplier ?? 1 }
        let dollars = Double(tokens.input) * input
            + Double(tokens.cacheWrite5m) * cacheWrite5m
            + Double(tokens.cacheWrite1h) * cacheWrite1h
            + Double(tokens.cacheRead) * cacheRead
            + Double(tokens.output) * output
        return dollars / 1_000_000 * scale
    }

    func matches(_ normalizedModel: String) -> Bool {
        if pattern.hasSuffix("*") { return normalizedModel.hasPrefix(String(pattern.dropLast()).lowercased()) }
        return normalizedModel == pattern.lowercased()
    }
}

/// Built-in prices plus the user's own rows (Settings → Modules → Usage).
nonisolated enum ModelPricing {
    /// Source of the built-in table, shown in the UI.
    static let sourceNote = "Anthropic list prices (platform.claude.com/docs/en/about-claude/pricing), fetched 2026-11-26"

    /// Claude API first-party list prices, per million tokens.
    static let builtIn: [ModelPrice] = {
        var rows: [ModelPrice] = []
        func add(_ patterns: [String], _ input: Double, _ output: Double, read: Double, w5: Double, w1: Double) {
            for pattern in patterns {
                rows.append(ModelPrice(pattern: pattern, input: input, output: output, cacheWrite5m: w5, cacheWrite1h: w1, cacheRead: read))
            }
        }
        add(["claude-fable-5-2", "claude-mythos-5-2"], 8, 40, read: 0.20, w5: 10, w1: 16)
        add(["claude-fable-5-1", "claude-mythos-5-1"], 10, 50, read: 0.25, w5: 12.5, w1: 20)
        add(["claude-fable-5", "claude-mythos-5"], 10, 50, read: 1, w5: 12.5, w1: 20)
        add(["claude-opus-5-5"], 4, 20, read: 0.20, w5: 5, w1: 8)
        add(["claude-opus-5", "claude-opus-4-8", "claude-opus-4-7", "claude-opus-4-6", "claude-opus-4-5"], 5, 25, read: 0.50, w5: 6.25, w1: 10)
        add(["claude-opus-4-1", "claude-opus-4"], 15, 75, read: 1.50, w5: 18.75, w1: 30)
        add(["claude-sonnet-5-5"], 2, 10, read: 0.10, w5: 2.5, w1: 4)
        add(["claude-sonnet-5"], 2, 10, read: 0.20, w5: 2.5, w1: 4)
        add(["claude-sonnet-4-6", "claude-sonnet-4-5", "claude-sonnet-4"], 3, 15, read: 0.30, w5: 3.75, w1: 6)
        add(["claude-haiku-4-5"], 1, 5, read: 0.10, w5: 1.25, w1: 2)
        var haiku = ModelPrice(pattern: "claude-haiku-5-5", input: 0.10, output: 0.50, cacheWrite5m: 0.125, cacheWrite1h: 0.20, cacheRead: 0.01)
        haiku.longPromptThreshold = 100_000
        haiku.longPromptMultiplier = 5   // $0.50 / $2.50 above 100K-token prompts
        rows.append(haiku)
        return rows
    }()

    /// `claude-sonnet-4-5-20250929` → `claude-sonnet-4-5`; `anthropic.claude-opus-5-5` → `claude-opus-5-5`;
    /// `claude-opus-4-5@20251101` → `claude-opus-4-5`.
    static func normalize(_ model: String) -> String {
        var id = model.lowercased().trimmingCharacters(in: .whitespaces)
        for prefix in ["anthropic.", "us.anthropic.", "eu.anthropic.", "models/"] where id.hasPrefix(prefix) {
            id.removeFirst(prefix.count)
        }
        if let at = id.firstIndex(of: "@") { id = String(id[..<at]) }
        func isDigit(_ c: Character) -> Bool { c.isASCII && c.isNumber }
        // Bedrock "-v1:0" version suffix.
        if let dash = id.lastIndex(of: "-") {
            let tail = id[id.index(after: dash)...]
            if tail.count > 1, tail.hasPrefix("v"), tail.dropFirst().allSatisfy({ isDigit($0) || $0 == ":" }) {
                id = String(id[..<dash])
            }
        }
        // "-20250929" date suffix (no regex: this runs for every record shown).
        if id.count > 9 {
            let suffix = id.suffix(9)
            if suffix.first == "-", suffix.dropFirst().allSatisfy(isDigit) { id.removeLast(9) }
        }
        return id
    }

    /// The user's rows win over built-in ones; exact patterns win over wildcards.
    static func price(for model: String, custom: [ModelPrice]) -> ModelPrice? {
        let id = normalize(model)
        for table in [custom, builtIn] {
            if let exact = table.first(where: { !$0.pattern.hasSuffix("*") && $0.matches(id) }) { return exact }
            if let wildcard = table.filter({ $0.pattern.hasSuffix("*") && $0.matches(id) })
                .max(by: { $0.pattern.count < $1.pattern.count }) { return wildcard }
        }
        return nil
    }
}
