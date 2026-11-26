import SwiftUI

struct AIAgentsSettingsPane: View {
    @Environment(SettingsStore.self) private var settings
    @Environment(APIKeyStore.self) private var apiKeys

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

            Section("Notch Chat") {
                Picker("Default model", selection: $settings.chatModel) {
                    ForEach(ChatModelChoice.allCases) { Text($0.displayName).tag($0) }
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text("System prompt")
                    TextEditor(text: $settings.chatSystemPrompt)
                        .font(.body)
                        .frame(height: 70)
                        .scrollContentBackground(.hidden)
                        .padding(6)
                        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                }
            }

            Section {
                LabeledContent("Local hook server") {
                    Label("Not running", systemImage: "circle.fill")
                        .labelStyle(StatusDotLabelStyle(color: .secondary))
                }
                TextField("Port", value: $settings.agentServerPort, format: .number.grouping(.never))
                    .help("127.0.0.1 port the hook server listens on (\(SettingsStore.agentPortRange.lowerBound)–\(SettingsStore.agentPortRange.upperBound)).")
                Button("Install Claude Code Hook…") {}
                    .disabled(true)
            } header: {
                Text("Claude Code Agent Hooks")
            } footer: {
                Text("The approval server and the one-click hook installer arrive in Phase 5.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear { apiKeys.refresh() }
    }
}

private struct APIKeyRow: View {
    let provider: APIKeyStore.Provider

    @Environment(APIKeyStore.self) private var apiKeys
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
