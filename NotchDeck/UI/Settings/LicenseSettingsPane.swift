import SwiftUI

struct LicenseSettingsPane: View {
    @Environment(LicenseManager.self) private var license
    @Environment(UpdateManager.self) private var updates

    @State private var keyDraft = ""
    @State private var confirmingDeactivation = false

    var body: some View {
        @Bindable var updates = updates

        Form {
            Section("Status") {
                LicenseStatusRow()
            }

            if case .licensed(let summary) = license.status {
                Section("This Mac") {
                    LabeledContent("Edition", value: summary.edition == .master ? "Master (unlimited)" : "Lifetime")
                    LabeledContent("License key", value: "••••-\(summary.keyHint)")
                    if let name = summary.customerName {
                        LabeledContent("Licensed to", value: name)
                    }
                    LabeledContent("Activated", value: summary.activatedAt.formatted(date: .abbreviated, time: .shortened))
                    HStack {
                        Text("Move your license to another Mac by deactivating it here first.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Deactivate This Mac…", role: .destructive) { confirmingDeactivation = true }
                            .disabled(license.activity != .idle)
                    }
                    errorText
                }
            } else {
                Section("Activate") {
                    HStack {
                        TextField("License key", text: $keyDraft, prompt: Text("XXXX-XXXX-XXXX-XXXX"))
                            .textFieldStyle(.roundedBorder)
                            .font(.body.monospaced())
                            .autocorrectionDisabled()
                            .onSubmit(activate)
                        Button(action: activate) {
                            if license.activity == .activating {
                                ProgressView().controlSize(.small)
                            } else {
                                Text("Activate")
                            }
                        }
                        .keyboardShortcut(.defaultAction)
                        .disabled(keyDraft.trimmingCharacters(in: .whitespaces).isEmpty || license.activity != .idle)
                    }
                    errorText
                    if !license.configuration.isActivationAvailable {
                        Text("License activation isn't configured in this build (LICENSE_API_BASE_URL / LICENSE_PUBLIC_KEY).")
                            .font(.callout)
                            .foregroundStyle(.orange)
                    }
                    if let purchaseURL = license.configuration.purchaseURL {
                        Link("Buy NotchDeck — one-time purchase", destination: purchaseURL)
                    }
                }
            }

            Section("Updates") {
                Toggle("Automatically check for updates", isOn: $updates.automaticallyChecksForUpdates)
                    .disabled(!updates.isConfigured)
                HStack {
                    LabeledContent("Version", value: updates.versionDescription)
                    Spacer()
                    Button("Check for Updates…") { updates.checkForUpdates() }
                        .disabled(!updates.canCheckForUpdates)
                }
                if !updates.isConfigured {
                    Text("Updates are disabled until SPARKLE_FEED_URL and SPARKLE_PUBLIC_ED_KEY are set in Config/NotchDeck.xcconfig.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .onAppear {
            license.clearError()
            license.refresh()
        }
        .confirmationDialog("Deactivate NotchDeck on this Mac?", isPresented: $confirmingDeactivation) {
            Button("Deactivate", role: .destructive) {
                Task { await license.deactivate() }
            }
        } message: {
            Text("This frees the activation so you can use your license on another Mac. NotchDeck’s modules lock here until you activate again.")
        }
    }

    @ViewBuilder
    private var errorText: some View {
        if let error = license.lastError {
            Label(error, systemImage: "exclamationmark.triangle.fill")
                .font(.callout)
                .foregroundStyle(.red)
        }
    }

    private func activate() {
        let key = keyDraft
        Task {
            if await license.activate(licenseKey: key) { keyDraft = "" }
        }
    }
}

private struct LicenseStatusRow: View {
    @Environment(LicenseManager.self) private var license

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.title2)
                .foregroundStyle(color)
                .frame(width: 30)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(detail).font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
            if case .trial = license.status, let badge = license.trialBadgeText {
                TrialBadge(text: badge, isExpired: false)
            }
        }
        .padding(.vertical, 4)
    }

    private var title: String {
        switch license.status {
        case .checking: "Checking license…"
        case .trial: "Free trial"
        case .trialExpired(.elapsed): "Free trial ended"
        case .trialExpired(.tampered): "Trial unavailable"
        case .licensed(let s): s.edition == .master ? "Licensed — Master key" : "Licensed"
        case .storageUnavailable: "License storage unavailable"
        }
    }

    private var detail: String {
        switch license.status {
        case .checking:
            ""
        case .trial(_, let endsAt):
            "All features are unlocked until \(endsAt.formatted(date: .abbreviated, time: .shortened))."
        case .trialExpired(.elapsed):
            "Enter a license key to unlock NotchDeck’s modules again."
        case .trialExpired(.tampered):
            "The trial record on this Mac couldn't be verified. Enter a license key to continue."
        case .licensed:
            "Thank you for supporting NotchDeck. Works offline; no account needed."
        case .storageUnavailable(let message):
            "NotchDeck stays unlocked meanwhile. \(message)"
        }
    }

    private var symbol: String {
        switch license.status {
        case .licensed: "checkmark.seal.fill"
        case .trialExpired: "lock.fill"
        case .storageUnavailable: "exclamationmark.triangle.fill"
        default: "clock.fill"
        }
    }

    private var color: Color {
        switch license.status {
        case .licensed: .green
        case .trialExpired: .orange
        case .storageUnavailable: .yellow
        default: .accentColor
        }
    }
}
