import Foundation
import Observation

/// BYOK API keys for the AI Chat module, stored only in the Keychain.
@Observable
final class APIKeyStore {
    enum Provider: String, CaseIterable, Identifiable {
        case anthropic, gemini

        var id: String { rawValue }

        var displayName: String {
            switch self {
            case .anthropic: "Claude (Anthropic)"
            case .gemini: "Gemini (Google)"
            }
        }

        var placeholder: String {
            switch self {
            case .anthropic: "sk-ant-…"
            case .gemini: "AIza…"
            }
        }

        fileprivate var account: String { "api.\(rawValue)" }
    }

    /// Which providers have a key saved (checked via attributes only, without reading secrets).
    private(set) var savedProviders: Set<Provider> = []

    @ObservationIgnored private let store: SecureStore

    init(store: SecureStore) {
        self.store = store
    }

    func refresh() {
        savedProviders = Set(Provider.allCases.filter { store.contains($0.account) })
    }

    func save(_ key: String, for provider: Provider) throws {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        try store.setData(Data(trimmed.utf8), for: provider.account)
        refresh()
    }

    func remove(for provider: Provider) throws {
        try store.removeData(for: provider.account)
        refresh()
    }

    /// Reads the secret; used by the chat clients (Phase 4).
    func key(for provider: Provider) throws -> String? {
        try store.data(for: provider.account).map { String(decoding: $0, as: UTF8.self) }
    }
}
