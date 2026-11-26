import Foundation
import Observation

nonisolated struct TodoItem: Codable, Identifiable, Equatable, Sendable {
    var id = UUID()
    var title: String
    var isDone = false
    var created = Date()
    var completed: Date?
}

/// A small local checklist, saved as JSON in Application Support/NotchDeck/todos.json.
@Observable
final class TodoStore {
    private(set) var items: [TodoItem] = []
    private(set) var lastError: String?

    @ObservationIgnored private let fileURL: URL

    init(directory: URL = URL.applicationSupportDirectory.appending(path: "NotchDeck", directoryHint: .isDirectory)) {
        fileURL = directory.appending(path: "todos.json")
        load()
    }

    /// Open items first (in the order added), then finished ones (most recently finished first).
    var sortedItems: [TodoItem] {
        let open = items.filter { !$0.isDone }
        let done = items.filter(\.isDone).sorted { ($0.completed ?? $0.created) > ($1.completed ?? $1.created) }
        return open + done
    }

    var openCount: Int { items.count(where: { !$0.isDone }) }
    var doneCount: Int { items.count(where: \.isDone) }

    func add(_ title: String) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        items.append(TodoItem(title: trimmed))
        save()
    }

    func toggle(_ id: TodoItem.ID) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        items[index].isDone.toggle()
        items[index].completed = items[index].isDone ? Date() : nil
        save()
    }

    func rename(_ id: TodoItem.ID, to title: String) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        if trimmed.isEmpty {
            items.remove(at: index)
        } else {
            items[index].title = trimmed
        }
        save()
    }

    func delete(_ id: TodoItem.ID) {
        items.removeAll { $0.id == id }
        save()
    }

    func clearDone() {
        items.removeAll(where: \.isDone)
        save()
    }

    // MARK: Persistence

    private func load() {
        guard let data = try? Data(contentsOf: fileURL) else { return }
        do {
            items = try JSONDecoder.todos.decode([TodoItem].self, from: data)
        } catch {
            // Keep the unreadable file for recovery instead of overwriting it.
            let backup = fileURL.deletingPathExtension().appendingPathExtension("unreadable.json")
            try? FileManager.default.removeItem(at: backup)
            try? FileManager.default.copyItem(at: fileURL, to: backup)
            lastError = "Couldn't read your to-dos; a copy was kept as \(backup.lastPathComponent)."
        }
    }

    private func save() {
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder.todos.encode(items).write(to: fileURL, options: .atomic)
            lastError = nil
        } catch {
            lastError = "Couldn't save to-dos: \(error.localizedDescription)"
        }
    }
}

private extension JSONEncoder {
    static var todos: JSONEncoder {
        // Default (seconds since 2001 as a Double) round-trips dates exactly; ISO-8601 drops fractions.
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }
}

private extension JSONDecoder {
    static var todos: JSONDecoder {
        JSONDecoder()
    }
}
