import AppKit
import Observation
import OSLog

/// Conversations, the composer draft, and the streaming loop for the notch chat.
@Observable
final class ChatStore {
    private(set) var conversations: [Conversation] = []
    private(set) var current: Conversation
    var draft = ""
    private(set) var draftAttachments: [ChatAttachment] = []
    private(set) var isStreaming = false
    private(set) var attachmentError: String?
    var showsHistory = false
    /// A file drag hovers over the open chat (highlights the composer).
    var isDropTargeted = false
    /// Tracked by the composer; ⌘V image/file paste only applies while it has focus.
    var isComposerFocused = false
    /// Bumped to ask the composer to take keyboard focus (the Open AI Chat shortcut).
    private(set) var focusRequest = 0

    /// Wired by the container: re-open the notch on the chat / hide it (screenshot capture).
    @ObservationIgnored var onShowChat: () -> Void = {}
    @ObservationIgnored var onHideNotch: () -> Void = {}
    /// Token usage of a finished reply (model actually used, provider, tokens) for the Usage module.
    @ObservationIgnored var onUsage: (String, ChatProvider, TokenCounts) -> Void = { _, _, _ in }
    @ObservationIgnored private var replyUsage = TokenCounts()

    @ObservationIgnored private let settings: SettingsStore
    @ObservationIgnored private let apiKeys: APIKeyStore
    @ObservationIgnored private let directory: URL
    @ObservationIgnored let catalog: ModelCatalog
    @ObservationIgnored private let makeClient: @MainActor (ChatModelRef, SettingsStore, APIKeyStore) throws -> ChatStreamingClient
    /// Models that rejected adaptive thinking this session (hand-added IDs with unknown capabilities).
    @ObservationIgnored private var thinkingUnsupported: Set<ChatModelRef> = []
    @ObservationIgnored private var streamTask: Task<Void, Never>?
    @ObservationIgnored private var pendingText = ""
    @ObservationIgnored private var pendingThinking = ""
    @ObservationIgnored private var flushTask: Task<Void, Never>?
    /// Set when the account rejects the refusal-fallback beta header; later requests skip it.
    @ObservationIgnored private(set) var refusalFallbacksUnavailable = false
    @ObservationIgnored private var pasteMonitor: Any?
    @ObservationIgnored private let logger = Logger(subsystem: "com.notchdeck.NotchDeck", category: "Chat")

    static var defaultDirectory: URL {
        URL.applicationSupportDirectory.appending(path: "NotchDeck/Chats", directoryHint: .isDirectory)
    }

    init(
        settings: SettingsStore,
        apiKeys: APIKeyStore,
        catalog: ModelCatalog,
        directory: URL = ChatStore.defaultDirectory,
        makeClient: @escaping @MainActor (ChatModelRef, SettingsStore, APIKeyStore) throws -> ChatStreamingClient = ChatStore.liveClient
    ) {
        self.settings = settings
        self.apiKeys = apiKeys
        self.catalog = catalog
        self.directory = directory
        self.makeClient = makeClient
        current = Conversation(model: settings.chatModel)
        conversations = Self.loadConversations(from: directory)
    }

    // MARK: Clients

    static func liveClient(for model: ChatModelRef, settings: SettingsStore, apiKeys: APIKeyStore) throws -> ChatStreamingClient {
        let provider = APIKeyStore.Provider(model.provider)
        let key = (try? apiKeys.key(for: provider))?.trimmingCharacters(in: .whitespacesAndNewlines)
        switch model.provider {
        case .anthropic:
            guard let key, !key.isEmpty else { throw ChatError.missingAPIKey("Claude") }
            return AnthropicChatClient(apiKey: key)
        case .gemini:
            guard let key, !key.isEmpty else { throw ChatError.missingAPIKey("Gemini") }
            return GeminiChatClient(apiKey: key)
        case .openAICompatible:
            guard let url = URL(string: settings.customEndpointURL.trimmingCharacters(in: .whitespaces)), url.scheme != nil else {
                throw ChatError.notConfigured("Set the custom endpoint's base URL in Settings → AI & Agents.")
            }
            return OpenAICompatibleChatClient(baseURL: url, apiKey: key)
        }
    }

    /// Whether the chosen model has what it needs (drives the composer's setup hint).
    var setupProblem: String? {
        switch current.model.provider {
        case .anthropic: return apiKeys.savedProviders.contains(.anthropic) ? nil : "Add your Claude API key to start chatting."
        case .gemini: return apiKeys.savedProviders.contains(.gemini) ? nil : "Add your Gemini API key to use Gemini."
        case .openAICompatible:
            return catalog.isConfigured(.openAICompatible) ? nil : "Set the custom endpoint's URL first."
        }
    }

    // MARK: Conversations

    func newChat() {
        stop()
        persistCurrent()
        current = Conversation(model: settings.chatModel)
        draftAttachments = []
        attachmentError = nil
        showsHistory = false
        requestFocus()
    }

    func open(_ conversation: Conversation) {
        stop()
        persistCurrent()
        current = conversation
        showsHistory = false
    }

    func delete(_ conversation: Conversation) {
        try? FileManager.default.removeItem(at: fileURL(for: conversation.id))
        conversations.removeAll { $0.id == conversation.id }
        if current.id == conversation.id { current = Conversation(model: settings.chatModel) }
    }

    func setModel(_ model: ChatModelRef) {
        current.model = model
        settings.chatModel = model // the pick becomes the default for new chats
    }

    func requestFocus() { focusRequest += 1 }

    // MARK: Attachments

    func attach(urls: [URL]) {
        let result = ChatAttachmentFactory.collect(urls.map { url in Result { try ChatAttachmentFactory.make(from: url) } })
        draftAttachments += result.attachments
        attachmentError = result.errors.first
    }

    /// Handles a drop onto the open chat. Returns false if nothing was attachable.
    @discardableResult
    func attach(from pasteboard: NSPasteboard) -> Bool {
        guard let result = ChatAttachmentFactory.fromPasteboard(pasteboard) else { return false }
        draftAttachments += result.attachments
        attachmentError = result.errors.first
        return !result.attachments.isEmpty
    }

    func removeAttachment(_ id: ChatAttachment.ID) {
        draftAttachments.removeAll { $0.id == id }
    }

    func pasteFromClipboard() {
        if !attach(from: .general) {
            if let text = NSPasteboard.general.string(forType: .string) { draft += text }
        }
    }

    /// Hides the notch, runs the system screen-selection tool, then reopens the chat with the image.
    func captureScreenSelection() {
        onHideNotch()
        Task {
            try? await Task.sleep(for: .milliseconds(300)) // let the notch get out of the way
            if let data = await ChatAttachmentFactory.captureScreenSelection() {
                do {
                    draftAttachments.append(try ChatAttachmentFactory.image(from: data, name: "Screen Selection"))
                    attachmentError = nil
                } catch {
                    attachmentError = error.localizedDescription
                }
            }
            onShowChat()
        }
    }

    func chooseFiles() {
        onHideNotch()
        NSApp.activate()
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.message = "Attach files to your message"
        if panel.runModal() == .OK { attach(urls: panel.urls) }
        onShowChat()
    }

    /// ⌘V in the composer: files and images become attachments; text pastes normally.
    func installPasteMonitor() {
        guard pasteMonitor == nil else { return }
        pasteMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.isComposerFocused, event.window is NotchPanel,
                  event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
                  event.charactersIgnoringModifiers == "v" else { return event }
            let pasteboard = NSPasteboard.general
            let hasText = pasteboard.string(forType: .string) != nil
            let hasFiles = pasteboard.canReadObject(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true])
            guard hasFiles || !hasText, self.attach(from: pasteboard) else { return event }
            return nil
        }
    }

    // MARK: Sending

    var canSend: Bool {
        !isStreaming && (!draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !draftAttachments.isEmpty)
    }

    func send() {
        guard canSend else { return }
        let user = ChatMessage(role: .user, text: draft.trimmingCharacters(in: .whitespacesAndNewlines), attachments: draftAttachments)
        draft = ""
        draftAttachments = []
        attachmentError = nil
        if current.messages.isEmpty { current.title = Conversation.titled(from: user.text.isEmpty ? (user.attachments.first?.name ?? "") : user.text) }
        current.messages.append(user)
        startReply()
    }

    /// Re-runs the last reply (after an error or refusal).
    func retry() {
        guard !isStreaming, let last = current.messages.last, last.role == .assistant else { return }
        current.messages.removeLast()
        startReply()
    }

    func stop() {
        streamTask?.cancel()
        streamTask = nil
    }

    private func startReply() {
        let choice = current.model
        let reply = ChatMessage(role: .assistant, text: "", modelID: choice.id, isComplete: false)
        current.messages.append(reply)
        current.updatedAt = Date()
        isStreaming = true
        persistCurrent()

        let history = ChatRequest.turns(from: current.messages.dropLast().map { $0 })
        let replyID = reply.id
        streamTask = Task { [weak self] in
            await self?.runReply(replyID: replyID, choice: choice, history: history)
        }
    }

    private func runReply(replyID: ChatMessage.ID, choice: ChatModelRef, history: [ChatMessage]) async {
        replyUsage = TokenCounts()
        defer {
            let servedBy = current.messages.first(where: { $0.id == replyID })?.modelID ?? choice.id
            if !replyUsage.isEmpty { onUsage(servedBy, choice.provider, replyUsage) }
            flush(into: replyID)
            update(replyID) { $0.isComplete = true }
            isStreaming = false
            streamTask = nil
            current.updatedAt = Date()
            persistCurrent()
        }
        do {
            let client = try makeClient(choice, settings, apiKeys)
            let info = catalog.info(for: choice)
            var useFallbacks = info.supportsRefusalFallbacks && !refusalFallbacksUnavailable
            var useThinking = info.usesAdaptiveThinking && !thinkingUnsupported.contains(choice)
            while true {
                let request = ChatRequest(
                    modelID: choice.id,
                    systemPrompt: settings.chatSystemPrompt,
                    turns: history,
                    maxTokens: info.replyTokenLimit,
                    useRefusalFallbacks: useFallbacks,
                    useAdaptiveThinking: useThinking
                )
                do {
                    try await consume(client.stream(request), into: replyID)
                    return
                } catch ChatError.betaHeaderRejected where useFallbacks {
                    // The account doesn't have the refusal-fallback beta: retry once without it.
                    logger.notice("Refusal-fallback beta unavailable; retrying without it")
                    refusalFallbacksUnavailable = true
                    useFallbacks = false
                } catch ChatError.thinkingRejected where useThinking {
                    // A model whose capabilities we guessed doesn't take adaptive thinking.
                    logger.notice("\(choice.id, privacy: .public) rejected thinking; retrying without it")
                    thinkingUnsupported.insert(choice)
                    useThinking = false
                }
            }
        } catch is CancellationError {
            // Stopped by the user; keep what streamed.
        } catch {
            let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            update(replyID) { $0.error = message }
        }
    }

    private func consume(_ stream: AsyncThrowingStream<ChatStreamEvent, Error>, into replyID: ChatMessage.ID) async throws {
        for try await event in stream {
            try Task.checkCancellation()
            switch event {
            case .model(let model):
                update(replyID) { $0.modelID = model }
            case .text(let text):
                pendingText += text
                scheduleFlush(into: replyID)
            case .thinking(let text):
                pendingThinking += text
                scheduleFlush(into: replyID)
            case .notice(let notice):
                update(replyID) { $0.notice = notice }
            case .usage(let tokens):
                replyUsage = replyUsage.merged(with: tokens)
            case .stop(let reason):
                if reason == "refusal" {
                    // The whole chain declined: discard the partial output.
                    flush(into: replyID)
                    update(replyID) {
                        $0.text = ""
                        $0.error = "Claude declined this request. Try rephrasing it."
                    }
                } else if reason == "max_tokens" {
                    update(replyID) { $0.notice = "Reply stopped at the length limit." }
                }
            }
        }
    }

    /// Streaming deltas arrive dozens of times a second; publish them ~20×/s so the Markdown
    /// view doesn't re-render per token.
    private func scheduleFlush(into replyID: ChatMessage.ID) {
        guard flushTask == nil else { return }
        flushTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(50))
            self?.flush(into: replyID)
        }
    }

    private func flush(into replyID: ChatMessage.ID) {
        flushTask?.cancel()
        flushTask = nil
        guard !pendingText.isEmpty || !pendingThinking.isEmpty else { return }
        let text = pendingText, thinking = pendingThinking
        pendingText = ""
        pendingThinking = ""
        update(replyID) {
            $0.text += text
            $0.thinking += thinking
        }
    }

    private func update(_ id: ChatMessage.ID, _ change: (inout ChatMessage) -> Void) {
        guard let index = current.messages.firstIndex(where: { $0.id == id }) else { return }
        change(&current.messages[index])
    }

    // MARK: Persistence

    private func fileURL(for id: Conversation.ID) -> URL {
        directory.appending(path: "\(id.uuidString).json")
    }

    private func persistCurrent() {
        guard !current.messages.isEmpty else { return }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try JSONEncoder().encode(current).write(to: fileURL(for: current.id), options: .atomic)
        } catch {
            logger.error("Saving chat failed: \(error.localizedDescription, privacy: .public)")
        }
        conversations.removeAll { $0.id == current.id }
        conversations.insert(current, at: 0)
    }

    private static func loadConversations(from directory: URL) -> [Conversation] {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return files
            .filter { $0.pathExtension == "json" }
            .compactMap { try? JSONDecoder().decode(Conversation.self, from: Data(contentsOf: $0)) }
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    // MARK: Utilities

    func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}
