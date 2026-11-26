import AppKit
import SwiftUI

/// Expanded Clipboard: recent clips, one click to copy back.
struct ClipboardModuleView: View {
    let tokens: ThemeTokens

    @Environment(ClipboardStore.self) private var clipboard

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if clipboard.access != .allowed {
                PermissionBanner(tokens: tokens)
            }
            if clipboard.items.isEmpty {
                VStack(spacing: 6) {
                    Image(systemName: "doc.on.clipboard").font(.system(size: 22)).foregroundStyle(tokens.secondaryText)
                    Text(clipboard.access == .allowed
                         ? "Copy something and it appears here. Kept in memory only, cleared when NotchDeck quits."
                         : "Clips appear here once NotchDeck may read the clipboard.")
                        .font(.system(size: 11))
                        .foregroundStyle(tokens.secondaryText)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(clipboard.items) { item in
                            ClipRow(item: item, tokens: tokens)
                        }
                    }
                }
                .scrollIndicators(.never)

                HStack {
                    Text("\(clipboard.items.count) clip\(clipboard.items.count == 1 ? "" : "s") · click to copy, then ⌘V")
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(tokens.secondaryText)
                    Spacer()
                    NotchPillButton(title: "Clear", symbol: "trash", tokens: tokens) { clipboard.clear() }
                }
            }
        }
    }
}

/// Explains macOS's "Paste from Other Apps" setting while reads would prompt (or are denied).
private struct PermissionBanner: View {
    let tokens: ThemeTokens

    @Environment(ClipboardStore.self) private var clipboard

    var body: some View {
        NotchCard(tokens: tokens) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: clipboard.access == .denied ? "hand.raised.fill" : "lock.shield")
                    .font(.system(size: 14))
                    .foregroundStyle(clipboard.access == .denied ? NotchStatusColor.warning : tokens.secondaryText)
                VStack(alignment: .leading, spacing: 4) {
                    Text(clipboard.access == .denied ? "Clipboard reading is turned off" : "Allow clipboard history")
                        .font(.system(size: 11.5, weight: .semibold))
                    Text(clipboard.access == .denied
                         ? "NotchDeck is set to Deny in System Settings → Privacy & Security → Paste from Other Apps."
                         : "macOS asks before apps read what you copy. To record clips automatically, set NotchDeck to Allow in System Settings → Privacy & Security → Paste from Other Apps. Grab Current Clip reads once (macOS may ask).")
                        .font(.system(size: 10.5))
                        .foregroundStyle(tokens.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 6) {
                        NotchPillButton(title: "Open System Settings", symbol: "gearshape", tokens: tokens) {
                            clipboard.openPrivacySettings()
                        }
                        if clipboard.access == .asks {
                            NotchPillButton(title: clipboard.hasUnreadChange ? "Grab New Clip" : "Grab Current Clip",
                                            symbol: "arrow.down.doc", tokens: tokens, prominent: clipboard.hasUnreadChange) {
                                clipboard.captureNow()
                            }
                        }
                    }
                    .padding(.top, 2)
                }
            }
        }
    }
}

private struct ClipRow: View {
    let item: ClipboardItem
    let tokens: ThemeTokens

    @Environment(ClipboardStore.self) private var clipboard
    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 8) {
            preview
            Spacer(minLength: 6)
            if clipboard.lastCopiedID == item.id {
                Label("Copied", systemImage: "checkmark")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(NotchStatusColor.good)
                    .labelStyle(.titleAndIcon)
            } else if isHovering {
                Button { clipboard.remove(item) } label: {
                    Image(systemName: "xmark").font(.system(size: 9, weight: .bold)).foregroundStyle(tokens.secondaryText)
                }
                .buttonStyle(.plain)
                .help("Remove from history")
            } else {
                Text(meta)
                    .font(.system(size: 9.5))
                    .foregroundStyle(tokens.secondaryText)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(isHovering ? tokens.controlFill : .clear, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
        .onTapGesture { clipboard.copy(item) }
        .contextMenu {
            Button("Copy") { clipboard.copy(item) }
            Divider()
            Button("Remove") { clipboard.remove(item) }
        }
        .help("Click to copy")
    }

    @ViewBuilder
    private var preview: some View {
        switch item.content {
        case .text(let text):
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: Self.looksLikeLink(text) ? "link" : "text.alignleft")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(tokens.secondaryText)
                    .frame(width: 16)
                    .padding(.top, 2)
                Text(text.trimmingCharacters(in: .whitespacesAndNewlines))
                    .font(.system(size: 11.5))
                    .lineLimit(2)
                    .truncationMode(.tail)
            }
        case .image(let data, _):
            HStack(spacing: 8) {
                if let image = NSImage(data: data) {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(maxWidth: 80, maxHeight: 40)
                        .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                    Text("Image · \(Int(image.size.width))×\(Int(image.size.height))")
                        .font(.system(size: 11))
                        .foregroundStyle(tokens.secondaryText)
                }
            }
        case .files(let urls):
            HStack(spacing: 8) {
                Image(nsImage: NSWorkspace.shared.icon(forFile: urls[0].path))
                    .resizable()
                    .frame(width: 18, height: 18)
                Text(urls.count == 1 ? urls[0].lastPathComponent : "\(urls[0].lastPathComponent) + \(urls.count - 1) more")
                    .font(.system(size: 11.5))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
    }

    private var meta: String {
        let time = item.date.formatted(.relative(presentation: .named))
        return [item.sourceApp, time].compactMap { $0 }.joined(separator: " · ")
    }

    private static func looksLikeLink(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.contains(" ") && (trimmed.hasPrefix("http://") || trimmed.hasPrefix("https://"))
    }
}
