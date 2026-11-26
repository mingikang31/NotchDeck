import SwiftUI
import UniformTypeIdentifiers

/// Expanded File Tray: drop zone, shelf of items (drag out, select, open), and actions.
struct FileTrayModuleView: View {
    let tokens: ThemeTokens

    @Environment(FileTrayStore.self) private var tray

    /// The whole notch is the drop target (see NotchRootView); this view only reflects it.
    private var isDropTargeted: Bool { tray.isDropTargeted }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if tray.availableItems.isEmpty {
                DropZone(tokens: tokens, isTargeted: isDropTargeted)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(tray.availableItems) { item in
                            TrayTile(item: item, tokens: tokens)
                        }
                    }
                    .padding(.vertical, 2)
                }
                .frame(height: 80)

                actionBar
            }
        }
        .overlay {
            if isDropTargeted && !tray.availableItems.isEmpty {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(tokens.primaryText.opacity(0.6), style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
                    .allowsHitTesting(false)
            }
        }
        .onAppear { tray.pruneMissing() }
    }

    private var actionBar: some View {
        HStack(spacing: 8) {
            let targets = tray.actionTargets
            Text(tray.selection.isEmpty ? "\(targets.count) item\(targets.count == 1 ? "" : "s")" : "\(targets.count) selected")
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(tokens.secondaryText)
            if let error = tray.lastError {
                Text(error).font(.system(size: 10.5)).foregroundStyle(.orange).lineLimit(1)
            }
            Spacer()
            TrayActionButton(title: "AirDrop", symbol: "airplayaudio", tokens: tokens) { tray.airDrop() }
                .disabled(!tray.canAirDrop)
            TrayActionButton(title: tray.isZipping ? "Zipping…" : "Zip", symbol: "doc.zipper", tokens: tokens) {
                Task { await tray.zipTargets() }
            }
            .disabled(tray.isZipping)
            TrayActionButton(title: tray.selection.isEmpty ? "Clear All" : "Remove", symbol: "trash", tokens: tokens) {
                if tray.selection.isEmpty { tray.clearAll() } else { tray.remove(tray.selection) }
            }
        }
    }
}

private struct DropZone: View {
    let tokens: ThemeTokens
    let isTargeted: Bool

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: isTargeted ? "tray.and.arrow.down.fill" : "tray.and.arrow.down")
                .font(.system(size: 22, weight: .semibold))
                .symbolEffect(.bounce, value: isTargeted)
            VStack(alignment: .leading, spacing: 3) {
                Text(isTargeted ? "Release to add" : "Drop files here")
                    .font(.system(size: 14, weight: .semibold))
                Text("Park files, images or text, then drag them out, AirDrop or zip them.")
                    .font(.system(size: 11))
                    .foregroundStyle(tokens.secondaryText)
            }
            Spacer()
        }
        .padding(.horizontal, 16)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(tokens.primaryText.opacity(isTargeted ? 0.7 : 0.22), style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
                .background(tokens.controlFill.opacity(isTargeted ? 1.5 : 0.6), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .animation(.easeOut(duration: 0.15), value: isTargeted)
    }
}

private struct TrayTile: View {
    let item: TrayItem
    let tokens: ThemeTokens

    @Environment(FileTrayStore.self) private var tray
    @State private var isHovering = false

    var body: some View {
        let isSelected = tray.selection.contains(item.id)
        VStack(spacing: 3) {
            Group {
                if let thumbnail = tray.thumbnails[item.id] {
                    Image(nsImage: thumbnail).resizable().aspectRatio(contentMode: .fit)
                } else {
                    Image(systemName: "doc").font(.system(size: 22)).foregroundStyle(tokens.secondaryText)
                }
            }
            .frame(width: 44, height: 40)

            Text(item.displayName)
                .font(.system(size: 9.5, weight: .medium))
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(width: 68)
            if let bytes = item.byteCount {
                Text(bytes.formatted(.byteCount(style: .file)))
                    .font(.system(size: 8.5).monospacedDigit())
                    .foregroundStyle(tokens.secondaryText)
            }
        }
        .padding(5)
        .background(isSelected ? tokens.controlSelectedFill : (isHovering ? tokens.controlFill : .clear),
                    in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay(alignment: .topTrailing) {
            if isHovering {
                Button { tray.remove([item.id]) } label: {
                    Image(systemName: "xmark.circle.fill").font(.system(size: 12)).symbolRenderingMode(.hierarchical)
                }
                .buttonStyle(.plain)
                .offset(x: 3, y: -3)
                .help("Remove from tray")
            }
        }
        .onHover { isHovering = $0 }
        .onTapGesture(count: 2) { if let url = tray.url(for: item) { NSWorkspace.shared.open(url) } }
        .onTapGesture { tray.toggleSelection(item.id) }
        .onDrag {
            tray.url(for: item).flatMap { NSItemProvider(contentsOf: $0) } ?? NSItemProvider()
        }
        .contextMenu {
            Button("Open") { if let url = tray.url(for: item) { NSWorkspace.shared.open(url) } }
            Button("Show in Finder") { if let url = tray.url(for: item) { NSWorkspace.shared.activateFileViewerSelecting([url]) } }
            Divider()
            Button("Remove from Tray") { tray.remove([item.id]) }
        }
        .onAppear { tray.loadThumbnail(for: item) }
        .help(item.isStaged ? "\(item.displayName) (kept by NotchDeck)" : item.displayName)
    }
}

private struct TrayActionButton: View {
    let title: String
    let symbol: String
    let tokens: ThemeTokens
    let action: () -> Void

    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: symbol)
                .font(.system(size: 10.5, weight: .semibold))
                .padding(.horizontal, 9)
                .padding(.vertical, 4)
                .background(tokens.controlFill, in: Capsule())
                .opacity(isEnabled ? 1 : 0.45)
        }
        .buttonStyle(.plain)
    }
}
