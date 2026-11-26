import Foundation

nonisolated enum ChatRole: String, Codable, Sendable {
    case user, assistant
}

/// A file, image or snippet attached to a user message.
nonisolated struct ChatAttachment: Codable, Identifiable, Equatable, Sendable {
    enum Kind: String, Codable, Sendable { case image, pdf, text }

    var id = UUID()
    var name: String
    var kind: Kind
    var mediaType: String
    var data: Data

    var text: String? { kind == .text ? String(decoding: data, as: UTF8.self) : nil }
    var base64: String { data.base64EncodedString() }

    var symbolName: String {
        switch kind {
        case .image: "photo"
        case .pdf: "doc.richtext"
        case .text: "doc.text"
        }
    }
}

nonisolated struct ChatMessage: Codable, Identifiable, Equatable, Sendable {
    var id = UUID()
    var role: ChatRole
    var text: String
    var attachments: [ChatAttachment] = []
    /// Summarized reasoning shown in a disclosure (never sent back to the model).
    var thinking = ""
    /// Model that actually answered (can differ from the requested one after a refusal fallback).
    var modelID: String?
    var notice: String?
    var error: String?
    var isComplete = true
    var createdAt = Date()

    /// Whether this message should be part of the history sent to the model.
    var isSendable: Bool {
        switch role {
        case .user: !text.isEmpty || !attachments.isEmpty
        case .assistant: error == nil && isComplete && !text.isEmpty
        }
    }
}

nonisolated struct Conversation: Codable, Identifiable, Equatable, Sendable {
    var id = UUID()
    var title = "New Chat"
    var model: ChatModelRef
    var messages: [ChatMessage] = []
    var createdAt = Date()
    var updatedAt = Date()

    static func titled(from text: String) -> String {
        let line = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? text
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return "New Chat" }
        return trimmed.count > 48 ? String(trimmed.prefix(47)) + "…" : trimmed
    }
}

/// Provider-neutral request.
nonisolated struct ChatRequest: Sendable {
    var modelID: String
    var systemPrompt: String
    /// Alternating turns, starting and ending with a user turn (see `turns(from:)`).
    var turns: [ChatMessage]
    var maxTokens = 32_000
    var useRefusalFallbacks = false
    /// Claude only: send adaptive thinking (models that support it; see `ChatModelInfo`).
    var useAdaptiveThinking = false

    /// Turns the API can accept: unfinished/failed assistant replies are dropped and consecutive
    /// same-role messages merged, so roles strictly alternate and start with the user.
    static func turns(from messages: [ChatMessage]) -> [ChatMessage] {
        var result: [ChatMessage] = []
        for message in messages where message.isSendable {
            if var last = result.last, last.role == message.role {
                last.text = [last.text, message.text].filter { !$0.isEmpty }.joined(separator: "\n\n")
                last.attachments += message.attachments
                result[result.count - 1] = last
            } else {
                result.append(message)
            }
        }
        while result.first?.role == .assistant { result.removeFirst() }
        return result
    }
}

nonisolated enum ChatStreamEvent: Equatable, Sendable {
    /// The model actually serving the reply.
    case model(String)
    case text(String)
    case thinking(String)
    /// Informational line, e.g. a refusal fallback switched models.
    case notice(String)
    case stop(reason: String?)
}

nonisolated enum ChatError: LocalizedError, Equatable, Sendable {
    case missingAPIKey(String)
    case notConfigured(String)
    case rejected(status: Int, message: String)
    /// The account doesn't have the refusal-fallback beta; retry without it.
    case betaHeaderRejected
    /// The model doesn't accept the thinking configuration; retry without it.
    case thinkingRejected
    case network(String)
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .missingAPIKey(let provider): "Add your \(provider) API key in Settings → AI & Agents."
        case .notConfigured(let what): what
        case .rejected(_, let message): message
        case .betaHeaderRejected: "The API rejected an optional feature header."
        case .thinkingRejected: "This model doesn't support thinking."
        case .network(let message): "Couldn't reach the server: \(message)"
        case .invalidResponse: "The server sent a response NotchDeck couldn't read."
        }
    }
}

/// A streaming chat backend.
nonisolated protocol ChatStreamingClient: Sendable {
    func stream(_ request: ChatRequest) -> AsyncThrowingStream<ChatStreamEvent, Error>
}

// MARK: - Server-Sent Events

nonisolated enum ServerSentEvents {
    /// Performs `request` and yields the payload of every `data:` line. Non-2xx responses are
    /// read in full and turned into an error by `makeError`.
    static func dataLines(
        _ request: URLRequest,
        session: URLSession = .shared,
        makeError: @escaping @Sendable (Int, Data) -> Error
    ) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task.detached {
                do {
                    let (bytes, response) = try await session.bytes(for: request)
                    guard let http = response as? HTTPURLResponse else { throw ChatError.invalidResponse }
                    guard (200..<300).contains(http.statusCode) else {
                        var body = Data()
                        for try await byte in bytes {
                            body.append(byte)
                            if body.count > 256_000 { break }
                        }
                        throw makeError(http.statusCode, body)
                    }
                    for try await line in bytes.lines where line.hasPrefix("data:") {
                        continuation.yield(String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces))
                    }
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish()
                } catch let error as URLError where error.code == .cancelled {
                    continuation.finish()
                } catch let error as URLError {
                    continuation.finish(throwing: ChatError.network(error.localizedDescription))
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Maps each `data:` payload through `parse` into chat events.
    static func events(
        _ request: URLRequest,
        makeError: @escaping @Sendable (Int, Data) -> Error,
        parse: @escaping @Sendable (String) throws -> [ChatStreamEvent]?
    ) -> AsyncThrowingStream<ChatStreamEvent, Error> {
        let lines = dataLines(request, makeError: makeError)
        return AsyncThrowingStream { continuation in
            let task = Task.detached {
                do {
                    for try await payload in lines {
                        guard let events = try parse(payload) else { break } // nil = end of stream
                        events.forEach { continuation.yield($0) }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    static func json(_ payload: String) -> [String: Any]? {
        guard let data = payload.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    static func errorMessage(from body: Data) -> String? {
        guard let json = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] else { return nil }
        if let error = json["error"] as? [String: Any], let message = error["message"] as? String { return message }
        if let message = json["message"] as? String { return message }
        return nil
    }
}
