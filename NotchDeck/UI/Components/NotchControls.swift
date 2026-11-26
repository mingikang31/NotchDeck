import SwiftUI

/// Small capsule button used across the notch modules (AirDrop, Clear, Start, …).
struct NotchPillButton: View {
    let title: String
    var symbol: String?
    let tokens: ThemeTokens
    var prominent = false
    let action: () -> Void

    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Button(action: action) {
            Group {
                if let symbol {
                    Label(title, systemImage: symbol)
                } else {
                    Text(title)
                }
            }
            .font(.system(size: 10.5, weight: .semibold))
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .background(prominent ? tokens.controlSelectedFill : tokens.controlFill, in: Capsule())
            .opacity(isEnabled ? 1 : 0.45)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

/// Icon-only round button for row actions.
struct NotchIconButton: View {
    let symbol: String
    let help: String
    let tokens: ThemeTokens
    var size: CGFloat = 22
    let action: () -> Void

    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size * 0.45, weight: .semibold))
                .frame(width: size, height: size)
                .foregroundStyle(tokens.secondaryText)
                .background(tokens.controlFill, in: Circle())
                .opacity(isEnabled ? 1 : 0.45)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(help)
    }
}

/// Rounded card background shared by the module views.
struct NotchCard<Content: View>: View {
    let tokens: ThemeTokens
    var padding: CGFloat = 10
    @ViewBuilder let content: Content

    var body: some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .background(tokens.controlFill, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.white.opacity(0.08)))
    }
}

/// Section label inside a card.
struct NotchSectionHeader<Trailing: View>: View {
    let title: String
    let symbol: String
    let tokens: ThemeTokens
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: symbol).font(.system(size: 9.5, weight: .bold))
            Text(title).font(.system(size: 10.5, weight: .semibold))
            Spacer(minLength: 6)
            trailing
        }
        .foregroundStyle(tokens.secondaryText)
    }
}

extension NotchSectionHeader where Trailing == EmptyView {
    init(title: String, symbol: String, tokens: ThemeTokens) {
        self.init(title: title, symbol: symbol, tokens: tokens) { EmptyView() }
    }
}

/// Status colors (reserved for state: good / warning / critical), always shown with a label.
enum NotchStatusColor {
    static let good = Color(red: 0.039, green: 0.675, blue: 0.137)
    static let warning = Color(red: 0.984, green: 0.702, blue: 0.082)
    static let critical = Color(red: 0.863, green: 0.235, blue: 0.239)
}
