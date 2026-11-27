import SwiftUI

/// Expanded AI Chat: model pill, conversation, composer with attachments, history drawer.
struct AIChatModuleView: View {
    let tokens: ThemeTokens

    @Environment(ChatStore.self) private var chat
    @Environment(\.settingsOpener) private var settingsOpener

    var body: some View {
        ZStack(alignment: .topLeading) {
            VStack(alignment: .leading, spacing: 8) {
                ChatHeader(tokens: tokens)
                if let problem = chat.setupProblem {
                    SetupHint(message: problem, tokens: tokens) { settingsOpener.open(.aiAgents) }
                } else {
                    MessageList(tokens: tokens)
                }
                Composer(tokens: tokens)
            }
            if chat.showsHistory {
                HistoryDrawer(tokens: tokens)
                    .transition(.move(edge: .leading).combined(with: .opacity))
            }
        }
        .animation(.smooth(duration: 0.25), value: chat.showsHistory)
        .onAppear { chat.installPasteMonitor() }
    }
}

// MARK: - Header

private struct ChatHeader: View {
    let tokens: ThemeTokens
    @Environment(ChatStore.self) private var chat
    @Environment(ModelCatalog.self) private var catalog
    @Environment(\.settingsOpener) private var settingsOpener

    var body: some View {
        HStack(spacing: 6) {
            Menu {
                ForEach(catalog.configuredProviders, id: \.self) { provider in
                    Section(provider.displayName) {
                        ForEach(catalog.models(for: provider)) { model in
                            Button {
                                chat.setModel(model.ref)
                            } label: {
                                if model.ref == chat.current.model {
                                    Label(model.displayName, systemImage: "checkmark")
                                } else {
                                    Text(model.displayName)
                                }
                            }
                        }
                    }
                }
                Divider()
                Button("Refresh Model Lists", systemImage: "arrow.clockwise") {
                    Task { await catalog.refreshAll() }
                }
                Button("Add Model or API Key…", systemImage: "plus") { settingsOpener.open(.aiAgents) }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "sparkles").font(.system(size: 9, weight: .bold))
                    Text(catalog.displayName(for: chat.current.model))
                        .font(.system(size: 10.5, weight: .semibold))
                        .lineLimit(1)
                    Image(systemName: "chevron.down").font(.system(size: 7, weight: .bold))
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .frame(maxWidth: 200)
                .background(tokens.controlFill, in: Capsule())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Model for this chat: \(chat.current.model.id)")

            Text(chat.current.title)
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(tokens.secondaryText)
                .lineLimit(1)

            Spacer(minLength: 6)

            headerButton("clock.arrow.circlepath", help: "Chat history") { chat.showsHistory.toggle() }
            headerButton("square.and.pencil", help: "New chat") { chat.newChat() }
        }
    }

    private func headerButton(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 10.5, weight: .semibold))
                .frame(width: 24, height: 20)
                .background(tokens.controlFill, in: Capsule())
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .foregroundStyle(tokens.secondaryText)
        .help(help)
    }
}

private struct SetupHint: View {
    let message: String
    let tokens: ThemeTokens
    let openSettings: () -> Void

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "key.fill").font(.system(size: 20, weight: .semibold))
            Text(message).font(.system(size: 12.5, weight: .medium)).multilineTextAlignment(.center)
            Button("Open AI Settings…", action: openSettings).controlSize(.small)
            Text("Keys stay in your Keychain and are sent only to their provider.")
                .font(.system(size: 10.5))
                .foregroundStyle(tokens.secondaryText)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Messages

private struct MessageList: View {
    let tokens: ThemeTokens
    @Environment(ChatStore.self) private var chat

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical) {
                LazyVStack(alignment: .leading, spacing: 12) {
                    if chat.current.messages.isEmpty {
                        EmptyChat(tokens: tokens)
                    }
                    ForEach(chat.current.messages) { message in
                        MessageRow(message: message, tokens: tokens)
                            .id(message.id)
                    }
                    Color.clear.frame(height: 1).id("bottom")
                }
                .padding(.trailing, 8)
            }
            .scrollIndicators(.visible)
            .onChange(of: chat.current.messages.last?.text.count) { _, _ in
                proxy.scrollTo("bottom", anchor: .bottom)
            }
            .onChange(of: chat.current.id) { _, _ in
                proxy.scrollTo("bottom", anchor: .bottom)
            }
            .onAppear { proxy.scrollTo("bottom", anchor: .bottom) }
        }
    }
}

private struct EmptyChat: View {
    let tokens: ThemeTokens

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Ask anything").font(.system(size: 14, weight: .semibold))
            Group {
                ShortcutHint(
                    action: .openAIChat,
                    text: { "\($0) opens this chat from anywhere" },
                    unsetText: "Set a shortcut in Settings → Shortcuts to open this chat from anywhere"
                )
                Label("⌘V pastes images and files as attachments", systemImage: "doc.on.clipboard")
                Label("Drop files on the notch, or capture part of your screen", systemImage: "viewfinder")
            }
            .font(.system(size: 11))
            .foregroundStyle(tokens.secondaryText)
        }
        .padding(.top, 8)
    }
}

private struct MessageRow: View {
    let message: ChatMessage
    let tokens: ThemeTokens

    @Environment(ChatStore.self) private var chat
    @State private var isHovering = false
    @State private var showsThinking = false

    var body: some View {
        if message.role == .user {
            HStack {
                Spacer(minLength: 40)
                VStack(alignment: .trailing, spacing: 5) {
                    if !message.attachments.isEmpty { AttachmentStrip(attachments: message.attachments, tokens: tokens) }
                    if !message.text.isEmpty {
                        MarkdownView.inline(message.text)
                            .font(.system(size: 12.5))
                            .textSelection(.enabled)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 7)
                            .background(tokens.controlSelectedFill, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }
                }
            }
        } else {
            VStack(alignment: .leading, spacing: 6) {
                if !message.thinking.isEmpty {
                    DisclosureGroup(isExpanded: $showsThinking) {
                        Text(message.thinking)
                            .font(.system(size: 11))
                            .foregroundStyle(tokens.secondaryText)
                            .textSelection(.enabled)
                    } label: {
                        Text(message.isComplete || !message.text.isEmpty ? "Thought process" : "Thinking…")
                            .font(.system(size: 10.5, weight: .medium))
                            .foregroundStyle(tokens.secondaryText)
                    }
                }
                if !message.text.isEmpty {
                    MarkdownView(markdown: message.text, tokens: tokens, copy: chat.copy)
                } else if !message.isComplete && message.thinking.isEmpty {
                    TypingIndicator(tokens: tokens)
                }
                if let notice = message.notice {
                    Label(notice, systemImage: "info.circle")
                        .font(.system(size: 10))
                        .foregroundStyle(tokens.secondaryText)
                }
                if let error = message.error {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Label(error, systemImage: "exclamationmark.triangle.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                        if message.id == chat.current.messages.last?.id {
                            Button("Retry") { chat.retry() }.controlSize(.small)
                        }
                    }
                }
                if message.isComplete, !message.text.isEmpty {
                    HStack(spacing: 10) {
                        Button {
                            chat.copy(message.text)
                        } label: {
                            Label("Copy Response", systemImage: "doc.on.doc")
                        }
                        .buttonStyle(.plain)
                        if let model = message.modelID {
                            Text(model)
                        }
                    }
                    .font(.system(size: 9.5, weight: .medium))
                    .foregroundStyle(tokens.secondaryText)
                    .opacity(isHovering ? 1 : 0)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .onHover { isHovering = $0 }
        }
    }
}

private struct TypingIndicator: View {
    let tokens: ThemeTokens

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 20.0)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            HStack(spacing: 4) {
                ForEach(0..<3, id: \.self) { index in
                    Circle()
                        .fill(tokens.secondaryText)
                        .frame(width: 5, height: 5)
                        .opacity(0.35 + 0.65 * max(0, sin(t * 5 - Double(index) * 0.7)))
                }
            }
        }
        .frame(height: 14)
    }
}

private struct AttachmentStrip: View {
    let attachments: [ChatAttachment]
    let tokens: ThemeTokens
    var remove: ((ChatAttachment.ID) -> Void)?

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(attachments) { attachment in
                    HStack(spacing: 5) {
                        if attachment.kind == .image, let image = NSImage(data: attachment.data) {
                            Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
                                .frame(width: 22, height: 22)
                                .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                        } else {
                            Image(systemName: attachment.symbolName).font(.system(size: 11))
                        }
                        Text(attachment.name).font(.system(size: 10.5)).lineLimit(1).truncationMode(.middle)
                        if let remove {
                            Button { remove(attachment.id) } label: {
                                Image(systemName: "xmark.circle.fill").font(.system(size: 10))
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(tokens.secondaryText)
                        }
                    }
                    .padding(.horizontal, 7)
                    .padding(.vertical, 4)
                    .frame(maxWidth: 180)
                    .background(tokens.controlFill, in: Capsule())
                }
            }
        }
    }
}

// MARK: - Composer

private struct Composer: View {
    let tokens: ThemeTokens

    @Environment(ChatStore.self) private var chat
    @Environment(FileTrayStore.self) private var tray
    @Environment(ModelCatalog.self) private var catalog
    @FocusState private var isFocused: Bool

    var body: some View {
        @Bindable var chat = chat

        VStack(alignment: .leading, spacing: 5) {
            if !chat.draftAttachments.isEmpty {
                AttachmentStrip(attachments: chat.draftAttachments, tokens: tokens) { chat.removeAttachment($0) }
            }
            if let error = chat.attachmentError {
                Text(error).font(.system(size: 10.5)).foregroundStyle(.orange).lineLimit(2)
            }
            HStack(alignment: .bottom, spacing: 6) {
                attachMenu
                TextField("Message \(catalog.displayName(for: chat.current.model))…", text: $chat.draft, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12.5))
                    .lineLimit(1...5)
                    .focused($isFocused)
                    .onKeyPress(.return, phases: .down) { press in
                        // Return sends; Shift-Return inserts a newline.
                        if press.modifiers.contains(.shift) { return .ignored }
                        chat.send()
                        return .handled
                    }
                    .padding(.vertical, 5)
                sendButton
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(tokens.controlFill, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(tokens.primaryText.opacity(chat.isDropTargeted ? 0.7 : (isFocused ? 0.25 : 0.08)),
                                  style: StrokeStyle(lineWidth: chat.isDropTargeted ? 1.5 : 1, dash: chat.isDropTargeted ? [5, 4] : []))
            }
        }
        .onChange(of: isFocused) { _, focused in chat.isComposerFocused = focused }
        .onChange(of: chat.focusRequest) { _, _ in isFocused = true }
        .onAppear { if chat.focusRequest > 0 { isFocused = true } }
    }

    private var attachMenu: some View {
        Menu {
            Button("Capture Screen Selection", systemImage: "viewfinder") { chat.captureScreenSelection() }
            Button("Paste from Clipboard", systemImage: "doc.on.clipboard") { chat.pasteFromClipboard() }
            Button("Choose File…", systemImage: "folder") { chat.chooseFiles() }
            let trayItems = tray.availableItems
            if !trayItems.isEmpty {
                Section("From File Tray") {
                    ForEach(trayItems) { item in
                        Button(item.displayName) {
                            if let url = tray.url(for: item) { chat.attach(urls: [url]) }
                        }
                    }
                }
            }
        } label: {
            Image(systemName: "paperclip")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(tokens.secondaryText)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .padding(.bottom, 5)
        .help("Attach")
    }

    private var sendButton: some View {
        Button {
            chat.isStreaming ? chat.stop() : chat.send()
        } label: {
            Image(systemName: chat.isStreaming ? "stop.fill" : "arrow.up")
                .font(.system(size: 10.5, weight: .bold))
                .frame(width: 22, height: 22)
                .background(chat.isStreaming || chat.canSend ? tokens.primaryText.opacity(0.9) : tokens.controlFill, in: Circle())
                .foregroundStyle(chat.isStreaming || chat.canSend ? Color.black : tokens.secondaryText)
        }
        .buttonStyle(.plain)
        .disabled(!chat.isStreaming && !chat.canSend)
        .padding(.bottom, 3)
        .help(chat.isStreaming ? "Stop" : "Send (Return)")
    }
}

// MARK: - History

private struct HistoryDrawer: View {
    let tokens: ThemeTokens
    @Environment(ChatStore.self) private var chat

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("History").font(.system(size: 12, weight: .semibold))
                Spacer()
                Button { chat.showsHistory = false } label: { Image(systemName: "xmark") }
                    .buttonStyle(.plain)
                    .foregroundStyle(tokens.secondaryText)
            }
            if chat.conversations.isEmpty {
                Text("No previous chats").font(.system(size: 11)).foregroundStyle(tokens.secondaryText)
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(chat.conversations) { conversation in
                        HistoryRow(conversation: conversation, isCurrent: conversation.id == chat.current.id, tokens: tokens)
                    }
                }
            }
        }
        .padding(10)
        .frame(width: 240)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(.black.opacity(0.85), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.white.opacity(0.1)))
    }
}

private struct HistoryRow: View {
    let conversation: Conversation
    let isCurrent: Bool
    let tokens: ThemeTokens

    @Environment(ChatStore.self) private var chat
    @Environment(ModelCatalog.self) private var catalog
    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 6) {
            VStack(alignment: .leading, spacing: 1) {
                Text(conversation.title).font(.system(size: 11, weight: .medium)).lineLimit(1)
                Text("\(catalog.displayName(for: conversation.model)) · \(conversation.updatedAt.formatted(.relative(presentation: .named)))")
                    .font(.system(size: 9.5))
                    .foregroundStyle(tokens.secondaryText)
            }
            Spacer()
            if isHovering {
                Button { chat.delete(conversation) } label: { Image(systemName: "trash").font(.system(size: 10)) }
                    .buttonStyle(.plain)
                    .foregroundStyle(tokens.secondaryText)
                    .help("Delete chat")
            }
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 5)
        .background(isCurrent ? tokens.controlSelectedFill : (isHovering ? tokens.controlFill : .clear),
                    in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
        .onTapGesture { chat.open(conversation) }
    }
}
