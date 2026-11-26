import Foundation

// MARK: - Anthropic (Claude)

/// Claude Messages API over raw HTTPS + SSE (Swift has no official Anthropic SDK).
nonisolated struct AnthropicChatClient: ChatStreamingClient {
    static let endpoint = URL(string: "https://api.anthropic.com/v1/messages")!
    static let apiVersion = "2026-10-21"
    /// Server-side refusal fallbacks: on a policy decline the API re-runs the request on a
    /// suitable model inside the same stream (`fallbacks: "default"`).
    static let refusalFallbackBeta = "server-side-fallback-2026-07-01"

    let apiKey: String

    func stream(_ request: ChatRequest) -> AsyncThrowingStream<ChatStreamEvent, Error> {
        var urlRequest = URLRequest(url: Self.endpoint)
        urlRequest.httpMethod = "POST"
        urlRequest.timeoutInterval = 600
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        urlRequest.setValue(Self.apiVersion, forHTTPHeaderField: "anthropic-version")
        if request.useRefusalFallbacks {
            urlRequest.setValue(Self.refusalFallbackBeta, forHTTPHeaderField: "anthropic-beta")
        }
        urlRequest.httpBody = try? JSONSerialization.data(withJSONObject: Self.body(for: request))
        return ServerSentEvents.events(urlRequest, makeError: Self.error(status:body:), parse: Self.events(from:))
    }

    static func body(for request: ChatRequest) -> [String: Any] {
        var body: [String: Any] = [
            "model": request.modelID,
            "max_tokens": request.maxTokens,
            "stream": true,
            "messages": request.turns.map(message),
        ]
        if request.useAdaptiveThinking {
            // Adaptive thinking with readable summaries, so the UI can show "Thinking…" content
            // instead of a silent pause (the default display on current models is "omitted").
            // Only for models that support it: older ones (e.g. Haiku 4.5) reject it with a 400.
            body["thinking"] = ["type": "adaptive", "display": "summarized"]
        }
        if !request.systemPrompt.isEmpty { body["system"] = request.systemPrompt }
        if request.useRefusalFallbacks { body["fallbacks"] = "default" }
        return body
    }

    /// History is sent as plain text for assistant turns (thinking blocks aren't replayed,
    /// which keeps every request valid regardless of model switches or fallbacks).
    static func message(_ message: ChatMessage) -> [String: Any] {
        guard message.role == .user else {
            return ["role": "assistant", "content": message.text]
        }
        var content: [[String: Any]] = message.attachments.map { attachment in
            switch attachment.kind {
            case .image:
                ["type": "image", "source": ["type": "base64", "media_type": attachment.mediaType, "data": attachment.base64]]
            case .pdf:
                ["type": "document", "title": attachment.name,
                 "source": ["type": "base64", "media_type": "application/pdf", "data": attachment.base64]]
            case .text:
                ["type": "document", "title": attachment.name,
                 "source": ["type": "text", "media_type": "text/plain", "data": attachment.text ?? ""]]
            }
        }
        if !message.text.isEmpty { content.append(["type": "text", "text": message.text]) }
        return ["role": "user", "content": content]
    }

    /// Parses one SSE `data:` payload. Event types: message_start, content_block_start/delta/stop,
    /// message_delta (stop_reason), message_stop, ping, error.
    static func events(from payload: String) throws -> [ChatStreamEvent]? {
        guard let json = ServerSentEvents.json(payload), let type = json["type"] as? String else { return [] }
        switch type {
        case "message_start":
            if let model = (json["message"] as? [String: Any])?["model"] as? String { return [.model(model)] }
        case "content_block_start":
            // A refusal fallback arrives as an ordinary content block of type "fallback";
            // streamed text is kept and the fallback model continues on the same stream.
            if let block = json["content_block"] as? [String: Any], block["type"] as? String == "fallback" {
                let to = (block["to"] as? [String: Any])?["model"] as? String
                return [.notice(to.map { "Continued with \($0)" } ?? "Continued with a fallback model")]
            }
        case "content_block_delta":
            guard let delta = json["delta"] as? [String: Any] else { return [] }
            switch delta["type"] as? String {
            case "text_delta": return (delta["text"] as? String).map { [.text($0)] } ?? []
            case "thinking_delta": return (delta["thinking"] as? String).map { [.thinking($0)] } ?? []
            default: return []
            }
        case "message_delta":
            if let reason = (json["delta"] as? [String: Any])?["stop_reason"] as? String { return [.stop(reason: reason)] }
        case "message_stop":
            return nil
        case "error":
            let error = json["error"] as? [String: Any]
            let kind = error?["type"] as? String ?? "error"
            let message = error?["message"] as? String ?? "The stream ended with an error."
            throw ChatError.rejected(status: kind == "overloaded_error" ? 529 : 500, message: friendly(kind: kind, message: message))
        default:
            break
        }
        return []
    }

    static func error(status: Int, body: Data) -> Error {
        let message = ServerSentEvents.errorMessage(from: body) ?? "HTTP \(status)"
        if status == 400, message.contains("anthropic-beta") { return ChatError.betaHeaderRejected }
        if status == 400, message.lowercased().contains("thinking") { return ChatError.thinkingRejected }
        let kind = switch status {
        case 401: "authentication_error"
        case 402: "billing_error"
        case 403: "permission_error"
        case 404: "not_found_error"
        case 413: "request_too_large"
        case 429: "rate_limit_error"
        case 529: "overloaded_error"
        case 500...: "api_error"
        default: "invalid_request_error"
        }
        return ChatError.rejected(status: status, message: friendly(kind: kind, message: message))
    }

    private static func friendly(kind: String, message: String) -> String {
        switch kind {
        case "authentication_error": "Claude rejected the API key. Check it in Settings → AI & Agents. (\(message))"
        case "billing_error": "Claude billing problem: \(message)"
        case "rate_limit_error": "Rate limited by Claude. Wait a moment and retry. (\(message))"
        case "overloaded_error": "Claude is temporarily overloaded. Retry in a moment."
        case "request_too_large": "The message (with attachments) is too large for Claude."
        case "api_error": "Claude had a server error. Retry in a moment. (\(message))"
        default: message
        }
    }
}

// MARK: - Google Gemini

nonisolated struct GeminiChatClient: ChatStreamingClient {
    let apiKey: String

    func stream(_ request: ChatRequest) -> AsyncThrowingStream<ChatStreamEvent, Error> {
        let model = request.modelID.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? request.modelID
        let url = URL(string: "https://generativelanguage.googleapis.com/v1beta/models/\(model):streamGenerateContent?alt=sse")!
        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "POST"
        urlRequest.timeoutInterval = 600
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
        urlRequest.httpBody = try? JSONSerialization.data(withJSONObject: Self.body(for: request))
        let modelID = request.modelID
        return ServerSentEvents.events(urlRequest, makeError: { status, body in
            let message = ServerSentEvents.errorMessage(from: body) ?? "HTTP \(status)"
            return ChatError.rejected(status: status, message: "Gemini: \(message)")
        }, parse: { payload in
            try Self.events(from: payload, modelID: modelID)
        })
    }

    static func body(for request: ChatRequest) -> [String: Any] {
        var body: [String: Any] = [
            "contents": request.turns.map { message -> [String: Any] in
                var parts: [[String: Any]] = message.attachments.map { attachment in
                    switch attachment.kind {
                    case .image, .pdf:
                        ["inline_data": ["mime_type": attachment.mediaType, "data": attachment.base64]]
                    case .text:
                        ["text": "File \(attachment.name):\n\(attachment.text ?? "")"]
                    }
                }
                if !message.text.isEmpty { parts.append(["text": message.text]) }
                return ["role": message.role == .user ? "user" : "model", "parts": parts]
            },
        ]
        if !request.systemPrompt.isEmpty {
            body["systemInstruction"] = ["parts": [["text": request.systemPrompt]]]
        }
        return body
    }

    static func events(from payload: String, modelID: String) throws -> [ChatStreamEvent]? {
        guard let json = ServerSentEvents.json(payload) else { return [] }
        if let blocked = (json["promptFeedback"] as? [String: Any])?["blockReason"] as? String {
            throw ChatError.rejected(status: 200, message: "Gemini blocked this request (\(blocked)).")
        }
        guard let candidate = (json["candidates"] as? [[String: Any]])?.first else { return [] }
        var events: [ChatStreamEvent] = []
        let parts = (candidate["content"] as? [String: Any])?["parts"] as? [[String: Any]] ?? []
        for part in parts where part["thought"] as? Bool != true {
            if let text = part["text"] as? String { events.append(.text(text)) }
        }
        if let reason = candidate["finishReason"] as? String {
            events.append(.stop(reason: reason))
        }
        return events
    }
}

// MARK: - OpenAI-compatible endpoint

/// Any server speaking the OpenAI chat-completions streaming format (local LLM servers, proxies).
nonisolated struct OpenAICompatibleChatClient: ChatStreamingClient {
    let baseURL: URL
    let apiKey: String?

    func stream(_ request: ChatRequest) -> AsyncThrowingStream<ChatStreamEvent, Error> {
        var urlRequest = URLRequest(url: baseURL.appending(path: "chat/completions"))
        urlRequest.httpMethod = "POST"
        urlRequest.timeoutInterval = 600
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let apiKey, !apiKey.isEmpty {
            urlRequest.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        urlRequest.httpBody = try? JSONSerialization.data(withJSONObject: Self.body(for: request))
        return ServerSentEvents.events(urlRequest, makeError: { status, body in
            let message = ServerSentEvents.errorMessage(from: body) ?? "HTTP \(status)"
            return ChatError.rejected(status: status, message: "Custom endpoint: \(message)")
        }, parse: Self.events(from:))
    }

    static func body(for request: ChatRequest) -> [String: Any] {
        var messages: [[String: Any]] = []
        if !request.systemPrompt.isEmpty { messages.append(["role": "system", "content": request.systemPrompt]) }
        for message in request.turns {
            guard message.role == .user, !message.attachments.isEmpty else {
                messages.append(["role": message.role.rawValue, "content": message.text])
                continue
            }
            var parts: [[String: Any]] = []
            var text = message.text
            for attachment in message.attachments {
                switch attachment.kind {
                case .image:
                    parts.append(["type": "image_url", "image_url": ["url": "data:\(attachment.mediaType);base64,\(attachment.base64)"]])
                case .text:
                    text = "File \(attachment.name):\n\(attachment.text ?? "")\n\n" + text
                case .pdf:
                    text = "[\(attachment.name): PDF attachments aren't supported by this endpoint]\n\n" + text
                }
            }
            parts.insert(["type": "text", "text": text], at: 0)
            messages.append(["role": "user", "content": parts])
        }
        return ["model": request.modelID, "stream": true, "messages": messages]
    }

    static func events(from payload: String) throws -> [ChatStreamEvent]? {
        if payload == "[DONE]" { return nil }
        guard let json = ServerSentEvents.json(payload) else { return [] }
        if let error = json["error"] as? [String: Any] {
            throw ChatError.rejected(status: 200, message: "Custom endpoint: \(error["message"] as? String ?? "stream error")")
        }
        guard let choice = (json["choices"] as? [[String: Any]])?.first else { return [] }
        var events: [ChatStreamEvent] = []
        if let content = (choice["delta"] as? [String: Any])?["content"] as? String, !content.isEmpty {
            events.append(.text(content))
        }
        if let reason = choice["finish_reason"] as? String { events.append(.stop(reason: reason)) }
        return events
    }
}
