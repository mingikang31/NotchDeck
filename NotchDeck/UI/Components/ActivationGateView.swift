import SwiftUI

/// Shown in place of the notch modules once the trial has ended without a license.
/// Basic controls (menu bar, Settings) remain available.
struct ActivationGateView: View {
    let tokens: ThemeTokens
    let enterLicense: () -> Void

    @Environment(LicenseManager.self) private var license

    var body: some View {
        HStack(spacing: 16) {
            Image(systemName: "lock.fill")
                .font(.system(size: 20, weight: .semibold))
                .frame(width: 52, height: 52)
                .background(tokens.controlFill, in: RoundedRectangle(cornerRadius: 12, style: .continuous))

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 14, weight: .semibold))
                Text("Activate a license to keep using NotchDeck’s modules.")
                    .font(.system(size: 11))
                    .foregroundStyle(tokens.secondaryText)
            }

            Spacer(minLength: 12)

            VStack(alignment: .trailing, spacing: 6) {
                Button("Enter License Key…", action: enterLicense)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                if let purchaseURL = license.configuration.purchaseURL {
                    Link("Buy NotchDeck", destination: purchaseURL)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(tokens.secondaryText)
                }
            }
        }
    }

    private var title: String {
        if case .trialExpired(.tampered) = license.status {
            return "Trial unavailable on this Mac"
        }
        return "Your free trial has ended"
    }
}
