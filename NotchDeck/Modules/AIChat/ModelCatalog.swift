import Foundation
import Observation
import OSLog

/// A specific model at a specific provider ("anthropic:claude-opus-5-5").
nonisolated struct ChatModelRef: Codable, Hashable, Sendable {
    var provider: ChatProvider
    var id: String

    static let defaultModel = ChatModelRef(provider: .anthropic, id: "claude-opus-5-5")

    var storageKey: String { "\(provider.rawValue):\(id)" }

    init(provider: ChatProvider, id: String) {
        self.provider = provider
        self.id = id
    }

    init?(storageKey: String) {
        if let legacy = Self.legacy(storageKey) { self = legacy; return }
        let parts = storageKey.split(separator: ":", maxSplits: 1).map(String.init)
        guard parts.count == 2, let provider = ChatProvider(rawValue: parts[0]), !parts[1].isEmpty else { return nil }
        self.init(provider: provider, id: parts[1])
    }

    /// Phase 4's first build stored a fixed enum ("claudeOpus", …); map those forward.
    static func legacy(_ value: String) -> ChatModelRef? {
        switch value {
        case "claudeOpus": ChatModelRef(provider: .anthropic, id: "claude-opus-5-5")
        case "claudeSonnet": ChatModelRef(provider: .anthropic, id: "claude-sonnet-5-5")
        case "claudeHaiku": ChatModelRef(provider: .anthropic, id: "claude-haiku-5-5")
        case "geminiFlash": ChatModelRef(provider: .gemini, id: "gemini-3.8-flash")
        case "geminiPro": ChatModelRef(provider: .gemini, id: "gemini-pro-latest")
        case "custom": .defaultModel
        default: nil
        }
    }

    // Decodes both the current {provider, id} object and a legacy enum string.
    private enum CodingKeys: String, CodingKey { case provider, id }

    init(from decoder: Decoder) throws {
        if let single = try? decoder.singleValueContainer().decode(String.self) {
            self = Self.legacy(single) ?? ChatModelRef(storageKey: single) ?? .defaultModel
            return
        }
        let container = try decoder.container(keyedBy: CodingKeys.self)
        provider = try container.decode(ChatProvider.self, forKey: .provider)
        id = try container.decode(String.self, forKey: .id)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(provider, forKey: .provider)
        try container.encode(id, forKey: .id)
    }
}

extension ChatProvider {
    var displayName: String {
        switch self {
        case .anthropic: "Claude"
        case .gemini: "Gemini"
        case .openAICompatible: "Custom Endpoint"
        }
    }
}

/// What NotchDeck knows about a model; capabilities come from the provider's model list.
nonisolated struct ChatModelInfo: Codable, Hashable, Identifiable, Sendable {
    var ref: ChatModelRef
    var displayName: String
    var maxOutputTokens: Int?
    /// Anthropic: `capabilities.thinking.types.adaptive.supported`. Nil = unknown (hand-added).
    var supportsAdaptiveThinking: Bool?
    var isUserAdded = false

    var id: String { ref.storageKey }

    /// Claude models documented to take server-side refusal fallbacks (`fallbacks: "default"`).
    static let refusalFallbackModels: Set<String> = [
        "claude-opus-5-5", "claude-sonnet-5-5", "claude-opus-5", "claude-fable-5-2", "claude-fable-5-1",
    ]

    var supportsRefusalFallbacks: Bool {
        ref.provider == .anthropic && Self.refusalFallbackModels.contains(ref.id)
    }

    /// Output budget for a chat reply: 32K, or the model's own cap if lower.
    var replyTokenLimit: Int {
        min(32_000, maxOutputTokens ?? 16_000)
    }

    /// Whether to send adaptive thinking. Unknown (hand-added) Claude IDs: guess from the name
    /// (current families support it); a 400 then makes the store retry without it.
    var usesAdaptiveThinking: Bool {
        guard ref.provider == .anthropic else { return false }
        if let supportsAdaptiveThinking { return supportsAdaptiveThinking }
        let id = ref.id
        return id.hasPrefix("claude-fable") || id.hasPrefix("claude-mythos")
            || id.hasPrefix("claude-opus-5") || id.hasPrefix("claude-sonnet-5") || id.hasPrefix("claude-haiku-5")
            || ["claude-opus-4-6", "claude-opus-4-7", "claude-opus-4-8", "claude-sonnet-4-6"].contains(id)
    }

    static func handAdded(_ ref: ChatModelRef) -> ChatModelInfo {
        ChatModelInfo(ref: ref, displayName: ref.id, isUserAdded: true)
    }
}

/// Every model the user can chat with: fetched live from each provider's model list (cached on
/// disk), plus model IDs the user added by hand.
@Observable
final class ModelCatalog {
    /// Fetches one provider's model list. Injectable for tests.
    typealias Fetcher = @MainActor (ChatProvider, _ apiKey: String?, _ baseURL: URL?) async throws -> [ChatModelInfo]

    private(set) var fetched: [ChatProvider: [ChatModelInfo]] = [:]
    private(set) var refreshing: Set<ChatProvider> = []
    private(set) var errors: [ChatProvider: String] = [:]
    private(set) var lastRefreshed: [ChatProvider: Date] = [:]

    @ObservationIgnored private let settings: SettingsStore
    @ObservationIgnored private let apiKeys: APIKeyStore
    @ObservationIgnored private let cacheURL: URL
    @ObservationIgnored private let fetcher: Fetcher
    @ObservationIgnored private let logger = Logger(subsystem: "com.notchdeck.NotchDeck", category: "Models")

    /// Shown before the first successful fetch (and if a fetch fails with nothing cached).
    static let builtIn: [ChatProvider: [ChatModelInfo]] = [
        .anthropic: [
            ChatModelInfo(ref: .init(provider: .anthropic, id: "claude-opus-5-5"), displayName: "Claude Opus 5.5", maxOutputTokens: 128_000, supportsAdaptiveThinking: true),
            ChatModelInfo(ref: .init(provider: .anthropic, id: "claude-sonnet-5-5"), displayName: "Claude Sonnet 5.5", maxOutputTokens: 128_000, supportsAdaptiveThinking: true),
            ChatModelInfo(ref: .init(provider: .anthropic, id: "claude-haiku-5-5"), displayName: "Claude Haiku 5.5", maxOutputTokens: 128_000, supportsAdaptiveThinking: true),
        ],
        .gemini: [
            ChatModelInfo(ref: .init(provider: .gemini, id: "gemini-3.8-flash"), displayName: "Gemini 3.8 Flash"),
            ChatModelInfo(ref: .init(provider: .gemini, id: "gemini-pro-latest"), displayName: "Gemini Pro (latest)"),
        ],
    ]

    static var defaultCacheURL: URL {
        URL.applicationSupportDirectory.appending(path: "NotchDeck/model-catalog.json")
    }

    init(settings: SettingsStore, apiKeys: APIKeyStore, cacheURL: URL = ModelCatalog.defaultCacheURL,
         fetcher: @escaping Fetcher = ModelCatalog.liveFetch) {
        self.settings = settings
        self.apiKeys = apiKeys
        self.cacheURL = cacheURL
        self.fetcher = fetcher
        if let data = try? Data(contentsOf: cacheURL),
           let cached = try? JSONDecoder().decode([String: [ChatModelInfo]].self, from: data) {
            for (key, models) in cached {
                if let provider = ChatProvider(rawValue: key) {
                    fetched[provider] = provider == .gemini ? Self.normalizedGemini(models) : models
                }
            }
        }
    }

    // MARK: Reading

    /// Providers the user has set up (a key, or for the custom endpoint a URL).
    var configuredProviders: [ChatProvider] {
        ChatProvider.allCases.filter(isConfigured)
    }

    func isConfigured(_ provider: ChatProvider) -> Bool {
        switch provider {
        case .anthropic: apiKeys.savedProviders.contains(.anthropic)
        case .gemini: apiKeys.savedProviders.contains(.gemini)
        case .openAICompatible: URL(string: settings.customEndpointURL)?.scheme != nil
        }
    }

    /// Fetched (or built-in) models for a provider, then hand-added ones.
    func models(for provider: ChatProvider) -> [ChatModelInfo] {
        let base = fetched[provider] ?? Self.builtIn[provider] ?? []
        let known = Set(base.map(\.ref))
        let added = settings.handAddedModels
            .filter { $0.provider == provider && !known.contains($0) }
            .map(ChatModelInfo.handAdded)
        return base + added
    }

    func info(for ref: ChatModelRef) -> ChatModelInfo {
        models(for: ref.provider).first { $0.ref == ref } ?? .handAdded(ref)
    }

    func displayName(for ref: ChatModelRef) -> String { info(for: ref).displayName }

    // MARK: Hand-added IDs

    func addModel(id: String, provider: ChatProvider) {
        let trimmed = id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let ref = ChatModelRef(provider: provider, id: trimmed)
        if !settings.handAddedModels.contains(ref) { settings.handAddedModels.append(ref) }
    }

    func removeHandAdded(_ ref: ChatModelRef) {
        settings.handAddedModels.removeAll { $0 == ref }
    }

    // MARK: Refreshing

    func refreshAll() async {
        for provider in configuredProviders { await refresh(provider) }
    }

    func refresh(_ provider: ChatProvider) async {
        guard isConfigured(provider), !refreshing.contains(provider) else { return }
        refreshing.insert(provider)
        defer { refreshing.remove(provider) }
        let key = try? apiKeys.key(for: APIKeyStore.Provider(provider))
        let baseURL = URL(string: settings.customEndpointURL.trimmingCharacters(in: .whitespaces))
        do {
            let models = try await fetcher(provider, key, baseURL)
            guard !models.isEmpty else { throw ChatError.notConfigured("The provider returned no chat models.") }
            fetched[provider] = models
            errors[provider] = nil
            lastRefreshed[provider] = Date()
            saveCache()
        } catch {
            errors[provider] = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            logger.notice("Model list refresh failed for \(provider.rawValue, privacy: .public): \(String(describing: error), privacy: .public)")
        }
    }

    private func saveCache() {
        let encodable = Dictionary(uniqueKeysWithValues: fetched.map { ($0.key.rawValue, $0.value) })
        do {
            try FileManager.default.createDirectory(at: cacheURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(encodable).write(to: cacheURL, options: .atomic)
        } catch {
            logger.error("Saving model cache failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: Live fetchers

    static func liveFetch(_ provider: ChatProvider, apiKey: String?, baseURL: URL?) async throws -> [ChatModelInfo] {
        switch provider {
        case .anthropic:
            guard let apiKey, !apiKey.isEmpty else { throw ChatError.missingAPIKey("Claude") }
            return try await fetchAnthropic(apiKey: apiKey)
        case .gemini:
            guard let apiKey, !apiKey.isEmpty else { throw ChatError.missingAPIKey("Gemini") }
            return try await fetchGemini(apiKey: apiKey)
        case .openAICompatible:
            guard let baseURL else { throw ChatError.notConfigured("Set the custom endpoint URL first.") }
            return try await fetchOpenAICompatible(baseURL: baseURL, apiKey: apiKey)
        }
    }

    private static func getJSON(_ request: URLRequest) async throws -> [String: Any] {
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw ChatError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else {
            throw ChatError.rejected(status: http.statusCode, message: ServerSentEvents.errorMessage(from: data) ?? "HTTP \(http.statusCode)")
        }
        guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { throw ChatError.invalidResponse }
        return json
    }

    /// Claude Models API: `GET /v1/models` (paginated with `after_id`).
    static func fetchAnthropic(apiKey: String) async throws -> [ChatModelInfo] {
        var models: [ChatModelInfo] = []
        var afterID: String?
        repeat {
            var components = URLComponents(string: "https://api.anthropic.com/v1/models")!
            components.queryItems = [URLQueryItem(name: "limit", value: "1000")] + (afterID.map { [URLQueryItem(name: "after_id", value: $0)] } ?? [])
            var request = URLRequest(url: components.url!)
            request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
            request.setValue(AnthropicChatClient.apiVersion, forHTTPHeaderField: "anthropic-version")
            let json = try await getJSON(request)
            models += parseAnthropicModels(json)
            afterID = (json["has_more"] as? Bool == true) ? json["last_id"] as? String : nil
        } while afterID != nil
        return models
    }

    static func parseAnthropicModels(_ json: [String: Any]) -> [ChatModelInfo] {
        (json["data"] as? [[String: Any]] ?? []).compactMap { model in
            guard let id = model["id"] as? String else { return nil }
            let thinking = (model["capabilities"] as? [String: Any])?["thinking"] as? [String: Any]
            let adaptive = ((thinking?["types"] as? [String: Any])?["adaptive"] as? [String: Any])?["supported"] as? Bool
            return ChatModelInfo(
                ref: ChatModelRef(provider: .anthropic, id: id),
                displayName: model["display_name"] as? String ?? id,
                maxOutputTokens: model["max_tokens"] as? Int,
                supportsAdaptiveThinking: adaptive ?? false
            )
        }
    }

    /// Gemini `GET /v1beta/models` (paginated with `pageToken`), keeping text-chat models.
    static func fetchGemini(apiKey: String) async throws -> [ChatModelInfo] {
        var models: [ChatModelInfo] = []
        var pageToken: String?
        repeat {
            var components = URLComponents(string: "https://generativelanguage.googleapis.com/v1beta/models")!
            components.queryItems = [URLQueryItem(name: "pageSize", value: "1000")] + (pageToken.map { [URLQueryItem(name: "pageToken", value: $0)] } ?? [])
            var request = URLRequest(url: components.url!)
            request.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
            let json = try await getJSON(request)
            models += parseGeminiModels(json)
            pageToken = (json["nextPageToken"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        } while pageToken != nil
        return models
    }

    /// Families that expose generateContent but aren't text chat: speech, images, music, video,
    /// embeddings, transcription, and agent-only models (seen in the live list, Nov 2026).
    static let geminiExcludedKeywords = [
        "embedding", "tts", "imagen", "veo", "aqa", "image", "native-audio", "live", "audio", "robotics",
        "banana", "lyria", "transcribe", "computer-use", "antigravity", "deep-research",
    ]

    /// Newest first: `-latest` aliases, then Gemini by version (descending), then other families (Gemma).
    static func parseGeminiModels(_ json: [String: Any]) -> [ChatModelInfo] {
        return normalizedGemini(unsortedGeminiModels(json))
    }

    /// Drops non-chat families and sorts. Also applied to the on-disk cache, so lists cached by an
    /// older build never show stale entries.
    static func normalizedGemini(_ models: [ChatModelInfo]) -> [ChatModelInfo] {
        func group(_ model: ChatModelInfo) -> Int {
            if model.ref.id.hasSuffix("-latest") { return 0 }
            return model.ref.id.hasPrefix("gemini") ? 1 : 2
        }
        return models
            .filter { model in !geminiExcludedKeywords.contains(where: model.ref.id.lowercased().contains) }
            .sorted { lhs, rhs in
                group(lhs) != group(rhs)
                    ? group(lhs) < group(rhs)
                    : lhs.displayName.localizedStandardCompare(rhs.displayName) == .orderedDescending
            }
    }

    private static func unsortedGeminiModels(_ json: [String: Any]) -> [ChatModelInfo] {
        (json["models"] as? [[String: Any]] ?? []).compactMap { model in
            guard let name = model["name"] as? String,
                  (model["supportedGenerationMethods"] as? [String] ?? []).contains("generateContent") else { return nil }
            let id = name.hasPrefix("models/") ? String(name.dropFirst(7)) : name
            guard !geminiExcludedKeywords.contains(where: id.lowercased().contains) else { return nil }
            return ChatModelInfo(
                ref: ChatModelRef(provider: .gemini, id: id),
                displayName: model["displayName"] as? String ?? id,
                maxOutputTokens: model["outputTokenLimit"] as? Int
            )
        }
    }

    /// OpenAI-compatible `GET {base}/models`.
    static func fetchOpenAICompatible(baseURL: URL, apiKey: String?) async throws -> [ChatModelInfo] {
        var request = URLRequest(url: baseURL.appending(path: "models"))
        if let apiKey, !apiKey.isEmpty { request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization") }
        return parseOpenAIModels(try await getJSON(request))
    }

    static func parseOpenAIModels(_ json: [String: Any]) -> [ChatModelInfo] {
        (json["data"] as? [[String: Any]] ?? []).compactMap { model in
            guard let id = model["id"] as? String else { return nil }
            return ChatModelInfo(ref: ChatModelRef(provider: .openAICompatible, id: id), displayName: id)
        }
        .sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
    }
}
