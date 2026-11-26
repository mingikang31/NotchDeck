import KeyboardShortcuts
import SwiftUI

struct AIAgentsSettingsPane: View {
    @Environment(SettingsStore.self) private var settings
    @Environment(APIKeyStore.self) private var apiKeys
    @Environment(ModelCatalog.self) private var catalog
    @Environment(AgentHookStore.self) private var agentHooks

    var body: some View {
        @Bindable var settings = settings

        Form {
            Section {
                ForEach(APIKeyStore.Provider.allCases) { provider in
                    APIKeyRow(provider: provider)
                }
            } header: {
                Text("API Keys")
            } footer: {
                Text("Keys are stored only in your macOS Keychain and sent only to their provider.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Section {
                Picker("Default model", selection: $settings.chatModel) {
                    ForEach(catalog.configuredProviders, id: \.self) { provider in
                        Section(provider.displayName) {
                            ForEach(catalog.models(for: provider)) { Text($0.displayName).tag($0.ref) }
                        }
                    }
                    if !catalog.configuredProviders.contains(settings.chatModel.provider) {
                        Text(catalog.displayName(for: settings.chatModel)).tag(settings.chatModel)
                    }
                }
                KeyboardShortcuts.Recorder("Open / close chat", name: .openAIChat)
                VStack(alignment: .leading, spacing: 6) {
                    Text("System prompt")
                    TextEditor(text: $settings.chatSystemPrompt)
                        .font(.body)
                        .frame(height: 70)
                        .scrollContentBackground(.hidden)
                        .padding(6)
                        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                }
            } header: {
                Text("Notch Chat")
            } footer: {
                Text("The shortcut opens the chat from any app; press it again to tuck the chat back into the notch. You can also change it in Settings → Shortcuts.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            ModelListsSection()

            Section {
                TextField("Base URL", text: $settings.customEndpointURL, prompt: Text("http://localhost:11434/v1"))
                    .onSubmit { Task { await catalog.refresh(.openAICompatible) } }
            } header: {
                Text("Custom OpenAI-Compatible Endpoint (Optional)")
            } footer: {
                Text("Any server that speaks the OpenAI chat-completions format, such as a local model server. Its models are listed from {Base URL}/models; you can also add model IDs above. Its API key (if it needs one) is under API Keys.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            ClaudeCodeHooksSection()
        }
        .formStyle(.grouped)
        .onAppear {
            apiKeys.refresh()
            agentHooks.refreshHookStatus()
        }
    }
}

private struct APIKeyRow: View {
    let provider: APIKeyStore.Provider

    @Environment(APIKeyStore.self) private var apiKeys
    @Environment(ModelCatalog.self) private var catalog
    @State private var draft = ""
    @State private var error: String?

    var body: some View {
        let isSaved = apiKeys.savedProviders.contains(provider)
        VStack(alignment: .leading, spacing: 4) {
            LabeledContent(provider.displayName) {
                HStack {
                    SecureField(isSaved ? "Saved in Keychain — enter a new key to replace" : provider.placeholder, text: $draft)
                        .textFieldStyle(.roundedBorder)
                        .frame(minWidth: 220)
                        .onSubmit(save)
                    Button("Save", action: save)
                        .disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty)
                    if isSaved {
                        Button("Remove", role: .destructive) {
                            do { try apiKeys.remove(for: provider) } catch { self.error = error.localizedDescription }
                        }
                    }
                }
            }
            if let error {
                Text(error).font(.caption).foregroundStyle(.red)
            }
        }
    }

    private func save() {
        do {
            try apiKeys.save(draft, for: provider)
            draft = ""
            error = nil
            // A new key unlocks that provider's live model list.
            if let chatProvider = ChatProvider(rawValue: provider.rawValue) {
                Task { await catalog.refresh(chatProvider) }
            }
        } catch {
            self.error = error.localizedDescription
        }
    }
}

struct StatusDotLabelStyle: LabelStyle {
    let color: Color

    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 6) {
            configuration.icon
                .font(.system(size: 7))
                .foregroundStyle(color)
            configuration.title
        }
    }
}

/// Live model lists per provider, plus model IDs added by hand.
private struct ModelListsSection: View {
    @Environment(ModelCatalog.self) private var catalog
    @Environment(SettingsStore.self) private var settings
    @State private var newModelID = ""
    @State private var newModelProvider: ChatProvider = .anthropic

    var body: some View {
        Section {
            if catalog.configuredProviders.isEmpty {
                Text("Add an API key above to list that provider's models.")
                    .foregroundStyle(.secondary)
            }
            ForEach(catalog.configuredProviders, id: \.self) { provider in
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(provider.displayName)
                        Text(status(for: provider))
                            .font(.caption)
                            .foregroundStyle(catalog.errors[provider] == nil ? Color.secondary : Color.orange)
                            .lineLimit(2)
                    }
                    Spacer()
                    if catalog.refreshing.contains(provider) {
                        ProgressView().controlSize(.small)
                    } else {
                        Button("Refresh") { Task { await catalog.refresh(provider) } }
                    }
                }
            }

            HStack {
                Picker("", selection: $newModelProvider) {
                    ForEach(ChatProvider.allCases, id: \.self) { Text($0.displayName).tag($0) }
                }
                .labelsHidden()
                .fixedSize()
                TextField("Model ID", text: $newModelID, prompt: Text("e.g. claude-opus-4-8 or gemini-2.5-pro"))
                    .onSubmit(add)
                Button("Add", action: add)
                    .disabled(newModelID.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            ForEach(settings.handAddedModels, id: \.self) { ref in
                HStack {
                    Text(ref.id).font(.body.monospaced())
                    Text(ref.provider.displayName).font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Remove", role: .destructive) { catalog.removeHandAdded(ref) }
                }
            }
        } header: {
            Text("Models")
        } footer: {
            Text("Each provider's full model list is fetched with your key and refreshed at launch. Add any other model ID by hand; it then appears in the chat's model menu.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    private func status(for provider: ChatProvider) -> String {
        if let error = catalog.errors[provider] { return "Couldn't refresh: \(error)" }
        let count = catalog.models(for: provider).count
        let updated = catalog.lastRefreshed[provider].map { " · updated " + $0.formatted(date: .omitted, time: .shortened) } ?? ""
        return "\(count) model\(count == 1 ? "" : "s")" + updated
    }

    private func add() {
        catalog.addModel(id: newModelID, provider: newModelProvider)
        newModelID = ""
    }
}

/// Coding-agent integration: hook server, per-agent hook install (Claude Code, Codex), chime, test.
private struct ClaudeCodeHooksSection: View {
    @Environment(SettingsStore.self) private var settings
    @Environment(AgentHookStore.self) private var hooks
    @State private var portDraft = ""

    var body: some View {
        @Bindable var settings = settings

        Section {
            LabeledContent("Local hook server") {
                Label(serverText, systemImage: "circle.fill")
                    .labelStyle(StatusDotLabelStyle(color: serverColor))
            }
            HStack {
                TextField("Port", text: $portDraft, prompt: Text("\(SettingsStore.defaultAgentPort)"))
                    .onSubmit(applyPort)
                    .frame(maxWidth: 160)
                Button("Apply", action: applyPort)
                    .disabled(Int(portDraft) == settings.agentServerPort || Int(portDraft) == nil)
                Spacer()
                Text("Listens on 127.0.0.1 only")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            ForEach(HookAgent.allCases) { agent in
                AgentHookRow(agent: agent, isServerRunning: isServerRunning)
            }

            Toggle("Chime when an agent finishes a task", isOn: $settings.agentChimeEnabled)
        } header: {
            Text("Coding Agent Hooks (Claude Code & Codex)")
        } footer: {
            Text("""
            Installing adds two hooks (permission requests and task-finished) to the agent's config, saving a backup next to it (…notchdeck-backup); nothing else in the file changes. \
            Claude Code: ~/.claude/settings.json (HTTP hooks). Codex: ~/.codex/hooks.json (a curl command per hook). Codex then asks you to trust new hooks once: run /hooks in Codex and trust both NotchDeck hooks. \
            If NotchDeck isn't running, or you don't answer within 2 minutes, the agent just asks in the terminal as usual. Nothing is ever approved automatically. Takes effect in new sessions.
            """)
            .font(.callout)
            .foregroundStyle(.secondary)
        }
        .onAppear { portDraft = String(settings.agentServerPort) }
    }

    private func applyPort() {
        guard let port = Int(portDraft) else { return }
        settings.agentServerPort = port
        portDraft = String(settings.agentServerPort) // shows the clamped value
    }

    private var isServerRunning: Bool {
        if case .running = hooks.serverState { return true }
        return false
    }

    private var serverText: String {
        switch hooks.serverState {
        case .running(let port): "Running on 127.0.0.1:\(port)"
        case .stopped: settings.enabledModules.contains(.agentHooks) ? "Stopped" : "Off (Agent Hooks module disabled)"
        case .failed(let reason): reason
        }
    }

    private var serverColor: Color {
        switch hooks.serverState {
        case .running: .green
        case .stopped: .secondary
        case .failed: .red
        }
    }
}

private struct AgentHookRow: View {
    let agent: HookAgent
    let isServerRunning: Bool

    @Environment(AgentHookStore.self) private var hooks

    var body: some View {
        let status = hooks.status(for: agent)
        VStack(alignment: .leading, spacing: 6) {
            LabeledContent(agent.displayName) {
                Label(statusText(status), systemImage: "circle.fill")
                    .labelStyle(StatusDotLabelStyle(color: statusColor(status)))
            }
            HStack {
                switch status {
                case .installed:
                    Button("Remove Hook", role: .destructive) { hooks.uninstallHook(agent) }
                case .needsUpdate:
                    Button("Update Hook") { hooks.installHook(agent) }.buttonStyle(.borderedProminent)
                    Button("Remove Hook", role: .destructive) { hooks.uninstallHook(agent) }
                case .notInstalled, .unreadable:
                    Button("Install \(agent.displayName) Hook") { hooks.installHook(agent) }
                        .buttonStyle(.borderedProminent)
                        .disabled(!agent.isPresentOnThisMac)
                }
                Spacer()
                Button("Send Test Request") { hooks.sendTestRequest(as: agent) }
                    .disabled(!isServerRunning)
                    .help("Shows a sample \(agent.displayName) approval card through the real server (nothing runs)")
            }
            if !agent.isPresentOnThisMac, status == .notInstalled {
                Text("\(agent.displayName) doesn't seem to be installed (\(agent.defaultConfigURL.deletingLastPathComponent().path.replacingOccurrences(of: FileManager.default.homeDirectoryForCurrentUser.path, with: "~")) not found).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if agent == .codex, status == .installed {
                Text("Codex only runs new hooks after you trust them: in Codex, run /hooks and trust both NotchDeck hooks (again after any update).")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            if let error = hooks.hookError[agent] {
                Text(error).font(.callout).foregroundStyle(.red)
            }
        }
    }

    private func statusText(_ status: AgentHookInstaller.Status) -> String {
        switch status {
        case .installed: "Installed"
        case .needsUpdate: "Needs update (port or token changed)"
        case .notInstalled: "Not installed"
        case .unreadable(let reason): reason
        }
    }

    private func statusColor(_ status: AgentHookInstaller.Status) -> Color {
        switch status {
        case .installed: .green
        case .needsUpdate: .orange
        case .notInstalled: .secondary
        case .unreadable: .red
        }
    }
}
