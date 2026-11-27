import AppKit
import Foundation
import Testing
@testable import NotchDeck

// MARK: - Test doubles

/// Thread-safe record of what a mock client was asked.
nonisolated final class RequestLog: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [ChatRequest] = []
    func append(_ request: ChatRequest) { lock.lock(); storage.append(request); lock.unlock() }
    var requests: [ChatRequest] { lock.lock(); defer { lock.unlock() }; return storage }
}

/// Plays back scripted events (or an error) per request.
nonisolated struct MockChatClient: ChatStreamingClient {
    let log: RequestLog
    let respond: @Sendable (ChatRequest, Int) -> Result<[ChatStreamEvent], ChatError>

    func stream(_ request: ChatRequest) -> AsyncThrowingStream<ChatStreamEvent, Error> {
        log.append(request)
        let result = respond(request, log.requests.count)
        return AsyncThrowingStream { continuation in
            switch result {
            case .success(let events):
                events.forEach { continuation.yield($0) }
                continuation.finish()
            case .failure(let error):
                continuation.finish(throwing: error)
            }
        }
    }
}

private func user(_ text: String, attachments: [ChatAttachment] = []) -> ChatMessage {
    ChatMessage(role: .user, text: text, attachments: attachments)
}

private func assistant(_ text: String, error: String? = nil, complete: Bool = true) -> ChatMessage {
    ChatMessage(role: .assistant, text: text, error: error, isComplete: complete)
}

// MARK: - Request shaping

struct ChatRequestTests {
    @Test func turnsDropFailedRepliesAndMergeSameRole() {
        let turns = ChatRequest.turns(from: [
            assistant("stray greeting"),
            user("first"),
            assistant("", error: "boom"),
            user("second"),
            assistant("answer"),
            user("third"),
            assistant("partial", complete: false),
        ])
        #expect(turns.map(\.role) == [.user, .assistant, .user])
        #expect(turns[0].text == "first\n\nsecond")
        #expect(turns[2].text == "third")
    }

    @Test func anthropicBodyUsesAdaptiveThinkingAndOptionalFallbacks() throws {
        let image = ChatAttachment(name: "shot.png", kind: .image, mediaType: "image/png", data: Data([1, 2, 3]))
        let notes = ChatAttachment(name: "notes.md", kind: .text, mediaType: "text/plain", data: Data("# hi".utf8))
        var request = ChatRequest(
            modelID: "claude-opus-5-5", systemPrompt: "Be brief.",
            turns: [user("What's this?", attachments: [image, notes]), assistant("A screenshot."), user("Thanks")]
        )
        var body = AnthropicChatClient.body(for: request)
        #expect(body["model"] as? String == "claude-opus-5-5")
        #expect(body["stream"] as? Bool == true)
        #expect(body["system"] as? String == "Be brief.")
        #expect(body["thinking"] == nil)          // only for models that support it
        #expect(body["fallbacks"] == nil)

        request.useAdaptiveThinking = true
        body = AnthropicChatClient.body(for: request)
        #expect((body["thinking"] as? [String: String]) == ["type": "adaptive", "display": "summarized"])

        let messages = try #require(body["messages"] as? [[String: Any]])
        #expect(messages.count == 3)
        let content = try #require(messages[0]["content"] as? [[String: Any]])
        #expect(content.map { $0["type"] as? String } == ["image", "document", "text"])
        #expect((content[0]["source"] as? [String: String])?["data"] == Data([1, 2, 3]).base64EncodedString())
        #expect((content[1]["source"] as? [String: String])?["type"] == "text")
        #expect(messages[1]["content"] as? String == "A screenshot.")

        request.useRefusalFallbacks = true
        body = AnthropicChatClient.body(for: request)
        #expect(body["fallbacks"] as? String == "default")
    }

    @Test func perModelRequestShaping() {
        func info(_ id: String, adaptive: Bool? = nil, maxOut: Int? = nil) -> ChatModelInfo {
            ChatModelInfo(ref: .init(provider: .anthropic, id: id), displayName: id, maxOutputTokens: maxOut, supportsAdaptiveThinking: adaptive)
        }
        #expect(info("claude-opus-5-5").supportsRefusalFallbacks)
        #expect(info("claude-sonnet-5-5").supportsRefusalFallbacks)
        #expect(!info("claude-haiku-5-5").supportsRefusalFallbacks)
        #expect(!info("claude-opus-4-8").supportsRefusalFallbacks)
        // Capabilities from the Models API win; unknown IDs are guessed from the family.
        #expect(!info("claude-haiku-4-5", adaptive: false).usesAdaptiveThinking)
        #expect(info("claude-opus-4-8", adaptive: true).usesAdaptiveThinking)
        #expect(info("claude-sonnet-5-5").usesAdaptiveThinking)
        #expect(!info("claude-3-5-haiku-latest").usesAdaptiveThinking)
        #expect(!ChatModelInfo(ref: .init(provider: .gemini, id: "gemini-3.8-flash"), displayName: "g").usesAdaptiveThinking)
        // Output budget: 32K or the model's own (lower) cap.
        #expect(info("claude-haiku-4-5", maxOut: 64_000).replyTokenLimit == 32_000)
        #expect(info("old", maxOut: 8_192).replyTokenLimit == 8_192)
    }

    @Test func geminiAndOpenAIBodies() throws {
        let image = ChatAttachment(name: "a.png", kind: .image, mediaType: "image/png", data: Data([9]))
        let request = ChatRequest(modelID: "m", systemPrompt: "sys", turns: [user("hi", attachments: [image]), assistant("yo"), user("ok")])

        let gemini = GeminiChatClient.body(for: request)
        let contents = try #require(gemini["contents"] as? [[String: Any]])
        #expect(contents.map { $0["role"] as? String } == ["user", "model", "user"])
        #expect(((contents[0]["parts"] as? [[String: Any]])?.first?["inline_data"] as? [String: String])?["mime_type"] == "image/png")
        #expect(gemini["systemInstruction"] != nil)

        let openAI = OpenAICompatibleChatClient.body(for: request)
        let messages = try #require(openAI["messages"] as? [[String: Any]])
        #expect(messages.map { $0["role"] as? String } == ["system", "user", "assistant", "user"])
        let parts = try #require(messages[1]["content"] as? [[String: Any]])
        #expect(parts.map { $0["type"] as? String } == ["text", "image_url"])
    }
}

// MARK: - Stream parsing

struct ChatStreamParsingTests {
    @Test func anthropicEvents() throws {
        #expect(try AnthropicChatClient.events(from: #"{"type":"message_start","message":{"id":"m","model":"claude-opus-5-5"}}"#) == [.model("claude-opus-5-5")])
        #expect(try AnthropicChatClient.events(from: #"{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Hello"}}"#) == [.text("Hello")])
        #expect(try AnthropicChatClient.events(from: #"{"type":"content_block_delta","index":0,"delta":{"type":"thinking_delta","thinking":"Hmm"}}"#) == [.thinking("Hmm")])
        #expect(try AnthropicChatClient.events(from: #"{"type":"content_block_delta","index":0,"delta":{"type":"signature_delta","signature":"x"}}"#) == [])
        #expect(try AnthropicChatClient.events(from: #"{"type":"message_delta","delta":{"stop_reason":"end_turn"},"usage":{"output_tokens":3}}"#) == [.usage(TokenCounts(output: 3)), .stop(reason: "end_turn")])
        #expect(try AnthropicChatClient.events(from: #"{"type":"ping"}"#) == [])
        #expect(try AnthropicChatClient.events(from: #"{"type":"message_stop"}"#) == nil)
    }

    @Test func anthropicFallbackBlockBecomesNotice() throws {
        let events = try AnthropicChatClient.events(from: #"{"type":"content_block_start","index":1,"content_block":{"type":"fallback","from":{"model":"claude-opus-5-5"},"to":{"model":"claude-opus-4-8"}}}"#)
        #expect(events == [.notice("Continued with claude-opus-4-8")])
    }

    @Test func anthropicStreamErrorThrows() {
        #expect(throws: ChatError.self) {
            _ = try AnthropicChatClient.events(from: #"{"type":"error","error":{"type":"overloaded_error","message":"Overloaded"}}"#)
        }
    }

    @Test func anthropicHTTPErrorsMapToFriendlyMessages() {
        let beta = AnthropicChatClient.error(status: 400, body: Data(#"{"type":"error","error":{"type":"invalid_request_error","message":"Unexpected value(s) `server-side-fallback-2026-07-01` for the `anthropic-beta` header."}}"#.utf8))
        #expect(beta as? ChatError == .betaHeaderRejected)
        let auth = AnthropicChatClient.error(status: 401, body: Data(#"{"type":"error","error":{"type":"authentication_error","message":"invalid x-api-key"}}"#.utf8))
        #expect((auth as? ChatError)?.errorDescription?.contains("API key") == true)
    }

    @Test func geminiEventsSkipThoughtsAndReportBlocks() throws {
        let chunk = #"{"candidates":[{"content":{"parts":[{"text":"plan","thought":true},{"text":"Answer"}]},"finishReason":"STOP"}]}"#
        #expect(try GeminiChatClient.events(from: chunk, modelID: "g") == [.text("Answer"), .stop(reason: "STOP")])
        #expect(throws: ChatError.self) {
            _ = try GeminiChatClient.events(from: #"{"promptFeedback":{"blockReason":"SAFETY"}}"#, modelID: "g")
        }
    }

    @Test func openAIEvents() throws {
        #expect(try OpenAICompatibleChatClient.events(from: #"{"choices":[{"delta":{"content":"Hi"},"finish_reason":null}]}"#) == [.text("Hi")])
        #expect(try OpenAICompatibleChatClient.events(from: #"{"choices":[{"delta":{},"finish_reason":"stop"}]}"#) == [.stop(reason: "stop")])
        #expect(try OpenAICompatibleChatClient.events(from: "[DONE]") == nil)
    }
}

// MARK: - Store

struct ChatStoreTests {
    private let directory = FileManager.default.temporaryDirectory.appending(path: "NotchDeckChatTests-\(UUID().uuidString)", directoryHint: .isDirectory)

    private func settings() -> SettingsStore {
        SettingsStore(defaults: UserDefaults(suiteName: "NotchDeckChatTests.\(UUID().uuidString)")!)
    }

    private func catalog(_ settings: SettingsStore, _ keys: APIKeyStore) -> ModelCatalog {
        ModelCatalog(settings: settings, apiKeys: keys,
                     cacheURL: directory.appending(path: "catalog.json")) { _, _, _ in [] }
    }

    private func store(_ settings: SettingsStore, log: RequestLog,
                       respond: @escaping @Sendable (ChatRequest, Int) -> Result<[ChatStreamEvent], ChatError>) -> ChatStore {
        let keys = APIKeyStore(store: InMemorySecureStore())
        return ChatStore(settings: settings, apiKeys: keys, catalog: catalog(settings, keys), directory: directory) { _, _, _ in
            MockChatClient(log: log, respond: respond)
        }
    }

    private func waitUntilIdle(_ chat: ChatStore) async {
        for _ in 0..<200 where chat.isStreaming { try? await Task.sleep(for: .milliseconds(10)) }
    }

    @Test func streamsReplyPersistsAndTitles() async throws {
        let log = RequestLog()
        let settings = settings()
        let chat = store(settings, log: log) { _, _ in
            .success([.model("claude-opus-5-5"), .thinking("Considering"), .text("Hello"), .text(", world"), .stop(reason: "end_turn")])
        }
        chat.draft = "Say hello\nplease"
        chat.send()
        await waitUntilIdle(chat)

        let reply = try #require(chat.current.messages.last)
        #expect(reply.text == "Hello, world")
        #expect(reply.thinking == "Considering")
        #expect(reply.isComplete)
        #expect(reply.modelID == "claude-opus-5-5")
        #expect(chat.current.title == "Say hello")
        #expect(chat.draft.isEmpty)

        let request = try #require(log.requests.first)
        #expect(request.modelID == "claude-opus-5-5")
        #expect(request.useRefusalFallbacks)          // Opus default → fallbacks on
        #expect(request.useAdaptiveThinking)
        #expect(request.maxTokens == 32_000)
        #expect(request.turns.map(\.role) == [.user])

        let keys = APIKeyStore(store: InMemorySecureStore())
        let reloaded = ChatStore(settings: settings, apiKeys: keys, catalog: catalog(settings, keys), directory: directory)
        #expect(reloaded.conversations.first?.messages.last?.text == "Hello, world")
    }

    @Test func refusalDiscardsPartialOutput() async throws {
        let chat = store(settings(), log: RequestLog()) { _, _ in
            .success([.text("Partial answ"), .stop(reason: "refusal")])
        }
        chat.draft = "risky"
        chat.send()
        await waitUntilIdle(chat)
        let reply = try #require(chat.current.messages.last)
        #expect(reply.text.isEmpty)
        #expect(reply.error?.contains("declined") == true)
    }

    @Test func rejectedBetaHeaderRetriesWithoutFallbacks() async throws {
        let log = RequestLog()
        let chat = store(settings(), log: log) { request, _ in
            request.useRefusalFallbacks ? .failure(.betaHeaderRejected) : .success([.text("ok"), .stop(reason: "end_turn")])
        }
        chat.draft = "hi"
        chat.send()
        await waitUntilIdle(chat)
        #expect(log.requests.map(\.useRefusalFallbacks) == [true, false])
        #expect(chat.current.messages.last?.text == "ok")
        #expect(chat.refusalFallbacksUnavailable)
    }

    @Test func errorsAreShownAndRetryResends() async throws {
        let log = RequestLog()
        let chat = store(settings(), log: log) { _, attempt in
            attempt == 1 ? .failure(.rejected(status: 529, message: "Claude is temporarily overloaded.")) : .success([.text("Back"), .stop(reason: "end_turn")])
        }
        chat.draft = "hello"
        chat.send()
        await waitUntilIdle(chat)
        #expect(chat.current.messages.last?.error == "Claude is temporarily overloaded.")

        chat.retry()
        await waitUntilIdle(chat)
        #expect(chat.current.messages.count == 2)
        #expect(chat.current.messages.last?.text == "Back")
        #expect(log.requests.last?.turns.map(\.text) == ["hello"])
    }

    @Test func followUpSendsHistory() async throws {
        let log = RequestLog()
        let chat = store(settings(), log: log) { _, attempt in .success([.text("reply \(attempt)"), .stop(reason: "end_turn")]) }
        chat.draft = "one"
        chat.send()
        await waitUntilIdle(chat)
        chat.draft = "two"
        chat.send()
        await waitUntilIdle(chat)
        #expect(log.requests.last?.turns.map(\.text) == ["one", "reply 1", "two"])
    }

    @Test func haikuSkipsRefusalFallbacks() async throws {
        let log = RequestLog()
        let chat = store(settings(), log: log) { _, _ in .success([.text("hi"), .stop(reason: "end_turn")]) }
        chat.setModel(ChatModelRef(provider: .anthropic, id: "claude-haiku-5-5"))
        chat.draft = "hi"
        chat.send()
        await waitUntilIdle(chat)
        #expect(log.requests.first?.modelID == "claude-haiku-5-5")
        #expect(log.requests.first?.useRefusalFallbacks == false)
    }

    @Test func handAddedModelThatRejectsThinkingIsRetriedWithoutIt() async throws {
        let log = RequestLog()
        let chat = store(settings(), log: log) { request, _ in
            request.useAdaptiveThinking ? .failure(.thinkingRejected) : .success([.text("fine"), .stop(reason: "end_turn")])
        }
        chat.setModel(ChatModelRef(provider: .anthropic, id: "claude-sonnet-5-preview"))
        chat.draft = "hi"
        chat.send()
        await waitUntilIdle(chat)
        #expect(log.requests.map(\.useAdaptiveThinking) == [true, false])
        #expect(chat.current.messages.last?.text == "fine")
    }

    @Test func missingKeySurfacesSetupMessage() async throws {
        let settings = settings()
        let keys = APIKeyStore(store: InMemorySecureStore())
        let chat = ChatStore(settings: settings, apiKeys: keys, catalog: catalog(settings, keys), directory: directory)
        #expect(chat.setupProblem != nil)
        chat.draft = "hi"
        chat.send()
        await waitUntilIdle(chat)
        #expect(chat.current.messages.last?.error?.contains("API key") == true)
    }
}

// MARK: - Markdown & attachments

struct MarkdownTests {
    @Test func parsesCommonBlocks() {
        let blocks = MarkdownBlock.parse("""
        # Title
        Some **bold** text
        continued

        - one
        - two
          wrapped
        1. first

        > quoted

        ```swift
        let x = 1
        ```
        | a | b |
        |---|---|
        ---
        """)
        #expect(blocks == [
            .heading(level: 1, text: "Title"),
            .paragraph("Some **bold** text\ncontinued"),
            .list(items: [
                .init(marker: "•", indent: 0, text: "one"),
                .init(marker: "•", indent: 0, text: "two wrapped"),
                .init(marker: "1.", indent: 0, text: "first"),
            ]),
            .quote("quoted"),
            .code(language: "swift", code: "let x = 1"),
            .table("| a | b |\n|---|---|"),
            .rule,
        ])
    }

    @Test func unclosedFenceWhileStreamingIsStillCode() {
        #expect(MarkdownBlock.parse("Here:\n```py\nprint(1)") == [.paragraph("Here:"), .code(language: "py", code: "print(1)")])
    }

    @Test func highlighterPreservesTextAndColorsTokens() {
        let code = #"let url = "https://x.dev" // note"#
        let highlighted = SyntaxHighlighter.highlight(code, language: "swift")
        #expect(String(highlighted.characters) == code)
        let colors = Set(highlighted.runs.compactMap(\.foregroundColor))
        #expect(colors.count >= 3) // default, keyword, string, comment
    }
}

struct ChatAttachmentTests {
    private let root = FileManager.default.temporaryDirectory.appending(path: "NotchDeckAttach-\(UUID().uuidString)", directoryHint: .isDirectory)

    private func write(_ name: String, _ data: Data) throws -> URL {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let url = root.appending(path: name)
        try data.write(to: url)
        return url
    }

    @Test func textFilesBecomeTextAttachments() throws {
        let attachment = try ChatAttachmentFactory.make(from: write("main.swift", Data("print(1)".utf8)))
        #expect(attachment.kind == .text)
        #expect(attachment.text == "print(1)")
    }

    @Test func largeImagesAreDownscaled() throws {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 3000, pixelsHigh: 1500, bitsPerSample: 8,
                                   samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                   bytesPerRow: 0, bitsPerPixel: 0)!
        let png = try #require(rep.representation(using: .png, properties: [:]))
        let attachment = try ChatAttachmentFactory.make(from: write("huge.png", png))
        let decoded = try #require(NSBitmapImageRep(data: attachment.data))
        #expect(attachment.kind == .image)
        #expect(max(decoded.pixelsWide, decoded.pixelsHigh) == 1568)
    }

    @Test func binaryFilesAreRejected() throws {
        let url = try write("blob.bin", Data([0, 1, 2, 0, 255]))
        #expect(throws: ChatAttachmentFactory.AttachmentError.unsupported("blob.bin")) {
            try ChatAttachmentFactory.make(from: url)
        }
    }
}

struct TallLayoutGeometryTests {
    @Test func tallLayoutSharesTopEdgeAndFitsItsPanel() {
        let g = NotchGeometry.compute(
            screenFrame: CGRect(x: 0, y: 0, width: 1512, height: 982),
            visibleFrame: CGRect(x: 0, y: 61, width: 1512, height: 888),
            safeAreaTop: 32,
            auxiliaryTopLeft: CGRect(x: 0, y: 950, width: 663.5, height: 32),
            auxiliaryTopRight: CGRect(x: 848.5, y: 950, width: 663.5, height: 32),
            preset: .medium
        )
        let tall = g.shapeRect(for: .expanded, layout: .tall)
        #expect(tall.height > g.shapeRect(for: .expanded).height)
        #expect(g.tallPanelFrame.contains(tall))
        #expect(g.tallPanelFrame.maxY == g.panelFrame.maxY)
        #expect(g.tallPanelFrame.width == g.panelFrame.width)
        #expect(tall.height <= 982 * 0.7)
    }
}

// MARK: - Model catalog

struct ModelCatalogTests {
    @Test func parsesAnthropicModelsWithCapabilities() {
        let json: [String: Any] = ["data": [
            ["id": "claude-opus-5-5", "display_name": "Claude Opus 5.5", "max_tokens": 128000,
             "capabilities": ["thinking": ["supported": true, "types": ["adaptive": ["supported": true], "enabled": ["supported": false]]]]],
            ["id": "claude-haiku-4-5", "display_name": "Claude Haiku 4.5", "max_tokens": 64000,
             "capabilities": ["thinking": ["supported": true, "types": ["adaptive": ["supported": false], "enabled": ["supported": true]]]]],
        ]]
        let models = ModelCatalog.parseAnthropicModels(json)
        #expect(models.map(\.ref.id) == ["claude-opus-5-5", "claude-haiku-4-5"])
        #expect(models[0].supportsAdaptiveThinking == true)
        #expect(models[1].supportsAdaptiveThinking == false)
        #expect(models[1].maxOutputTokens == 64000)
        #expect(models[1].displayName == "Claude Haiku 4.5")
    }

    @Test func geminiListKeepsOnlyTextChatModels() {
        let json: [String: Any] = ["models": [
            ["name": "models/gemini-3.8-flash", "displayName": "Gemini 3.8 Flash", "supportedGenerationMethods": ["generateContent", "countTokens"], "outputTokenLimit": 65536],
            ["name": "models/gemini-2.5-pro", "displayName": "Gemini 2.5 Pro", "supportedGenerationMethods": ["generateContent"]],
            ["name": "models/text-embedding-004", "supportedGenerationMethods": ["embedContent"]],
            ["name": "models/gemini-2.5-flash-preview-tts", "supportedGenerationMethods": ["generateContent"]],
            ["name": "models/gemini-2.5-flash-image", "supportedGenerationMethods": ["generateContent"]],
            ["name": "models/nano-banana-pro-preview", "displayName": "Nano Banana Pro", "supportedGenerationMethods": ["generateContent"]],
            ["name": "models/lyria-3.5", "supportedGenerationMethods": ["generateContent"]],
            ["name": "models/deep-research-preview-04-2026", "supportedGenerationMethods": ["generateContent"]],
            ["name": "models/gemma-4-31b-it", "displayName": "Gemma 4 31B IT", "supportedGenerationMethods": ["generateContent"]],
            ["name": "models/gemini-pro-latest", "displayName": "Gemini Pro Latest", "supportedGenerationMethods": ["generateContent"]],
        ]]
        let models = ModelCatalog.parseGeminiModels(json)
        #expect(models.map(\.ref.id) == ["gemini-pro-latest", "gemini-3.8-flash", "gemini-2.5-pro", "gemma-4-31b-it"])
        #expect(models[1].maxOutputTokens == 65536)
    }

    @Test func openAIListIsSortedNaturally() {
        let models = ModelCatalog.parseOpenAIModels(["data": [["id": "qwen3:14b"], ["id": "llama3.3"], ["id": "gemma3:4b"]]])
        #expect(models.map(\.ref.id) == ["gemma3:4b", "llama3.3", "qwen3:14b"])
    }

    @Test func legacySettingsAndChatsMigrate() throws {
        #expect(ChatModelRef(storageKey: "claudeSonnet") == ChatModelRef(provider: .anthropic, id: "claude-sonnet-5-5"))
        #expect(ChatModelRef(storageKey: "gemini:gemini-2.5-pro") == ChatModelRef(provider: .gemini, id: "gemini-2.5-pro"))
        #expect(ChatModelRef(storageKey: "openAICompatible:qwen3:14b")?.id == "qwen3:14b")
        #expect(ChatModelRef(storageKey: "nonsense") == nil)

        // A chat saved by the first Phase 4 build stored the model as a bare enum string.
        let legacyJSON = #"{"id":"\#(UUID().uuidString)","title":"Old","model":"claudeHaiku","messages":[],"createdAt":0,"updatedAt":0}"#
        let conversation = try JSONDecoder().decode(Conversation.self, from: Data(legacyJSON.utf8))
        #expect(conversation.model == ChatModelRef(provider: .anthropic, id: "claude-haiku-5-5"))
        let roundTrip = try JSONDecoder().decode(Conversation.self, from: JSONEncoder().encode(conversation))
        #expect(roundTrip.model == conversation.model)
    }

    @Test func fetchedListsReplaceBuiltInsAndKeepHandAddedIDs() async {
        let defaults = UserDefaults(suiteName: "NotchDeckCatalog.\(UUID().uuidString)")!
        let settings = SettingsStore(defaults: defaults)
        let secrets = InMemorySecureStore()
        let keys = APIKeyStore(store: secrets)
        try? keys.save("sk-ant-test", for: .anthropic)
        let cache = FileManager.default.temporaryDirectory.appending(path: "catalog-\(UUID().uuidString).json")
        let catalog = ModelCatalog(settings: settings, apiKeys: keys, cacheURL: cache) { provider, key, _ in
            #expect(provider == .anthropic)
            #expect(key == "sk-ant-test")
            return [ChatModelInfo(ref: .init(provider: .anthropic, id: "claude-fable-5-2"), displayName: "Claude Fable 5.2", supportsAdaptiveThinking: true)]
        }
        #expect(catalog.models(for: .anthropic).count == 3) // built-ins before any fetch
        await catalog.refresh(.anthropic)
        catalog.addModel(id: " claude-opus-4-8 ", provider: .anthropic)
        #expect(catalog.models(for: .anthropic).map(\.ref.id) == ["claude-fable-5-2", "claude-opus-4-8"])
        #expect(catalog.models(for: .anthropic).last?.isUserAdded == true)
        #expect(catalog.configuredProviders == [.anthropic])

        // The fetched list is cached for the next launch.
        let relaunched = ModelCatalog(settings: settings, apiKeys: keys, cacheURL: cache) { _, _, _ in [] }
        #expect(relaunched.models(for: .anthropic).first?.ref.id == "claude-fable-5-2")
    }
}
