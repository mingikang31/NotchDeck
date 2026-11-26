import AppKit
import SwiftUI

/// Expanded Live Activities: battery, connected Bluetooth devices, and recent downloads
/// (drag out, AirDrop, or drop into the File Tray).
struct LiveActivitiesModuleView: View {
    let tokens: ThemeTokens

    @Environment(LiveActivitiesStore.self) private var live
    @Environment(SettingsStore.self) private var settings
    @Environment(\.settingsOpener) private var settingsOpener

    var body: some View {
        let activation = live.activation
        let showsBattery = activation.battery && live.hasBattery
        VStack(alignment: .leading, spacing: 8) {
            if showsBattery || activation.bluetooth {
                HStack(alignment: .top, spacing: 8) {
                    if showsBattery { BatteryCard(status: live.battery, tokens: tokens).frame(width: 200) }
                    if activation.bluetooth { DevicesCard(devices: live.devices, tokens: tokens) }
                }
                .fixedSize(horizontal: false, vertical: true)
            }
            if activation.downloads {
                DownloadsCard(tokens: tokens)
            }
            if !showsBattery && !activation.bluetooth && !activation.downloads {
                HStack {
                    Text("Battery, Bluetooth and Downloads are all turned off.")
                        .font(.system(size: 11))
                        .foregroundStyle(tokens.secondaryText)
                    Spacer()
                    NotchPillButton(title: "Settings…", tokens: tokens) { settingsOpener.open(.modules) }
                }
            }
        }
        .onAppear { live.viewAppeared() }
        .onDisappear { live.viewDisappeared() }
    }
}

// MARK: Battery

private struct BatteryCard: View {
    let status: BatteryStatus?
    let tokens: ThemeTokens

    var body: some View {
        NotchCard(tokens: tokens) {
            VStack(alignment: .leading, spacing: 6) {
                NotchSectionHeader(title: "Battery", symbol: "battery.100percent", tokens: tokens)
                if let status {
                    HStack(spacing: 10) {
                        BatteryGlyph(status: status, tokens: tokens)
                        VStack(alignment: .leading, spacing: 0) {
                            Text("\(status.percent)%")
                                .font(.system(size: 18, weight: .semibold).monospacedDigit())
                                .contentTransition(.numericText())
                            Text(status.stateDescription)
                                .font(.system(size: 10.5))
                                .foregroundStyle(tokens.secondaryText)
                        }
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text(status.timeDescription ?? (status.isPluggedIn && !status.isCharging ? " " : "Estimating time…"))
                        Text(powerLine(status))
                        if let health = healthLine(status) { Text(health) }
                    }
                    .font(.system(size: 10).monospacedDigit())
                    .foregroundStyle(tokens.secondaryText)
                    .lineLimit(1)
                } else {
                    Text("Reading battery…").font(.system(size: 11)).foregroundStyle(tokens.secondaryText)
                }
            }
        }
    }

    private func powerLine(_ status: BatteryStatus) -> String {
        var parts: [String] = []
        if let watts = status.batteryWatts, abs(watts) >= 0.05 {
            parts.append(String(format: "%@%.1f W", watts > 0 ? "+" : "−", abs(watts)))
        }
        if let adapter = status.adapterWatts { parts.append("\(adapter) W adapter") }
        return parts.isEmpty ? " " : parts.joined(separator: " · ")
    }

    private func healthLine(_ status: BatteryStatus) -> String? {
        let parts = [status.healthPercent.map { "Health \($0)%" }, status.cycleCount.map { "\($0) cycles" }].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

/// Battery outline with a fill for the charge: green on power, amber ≤ 20 %, red ≤ 10 %.
struct BatteryGlyph: View {
    let status: BatteryStatus
    let tokens: ThemeTokens
    var width: CGFloat = 34
    var height: CGFloat = 16

    var body: some View {
        HStack(spacing: 1.5) {
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: height * 0.28, style: .continuous)
                    .strokeBorder(tokens.secondaryText.opacity(0.7), lineWidth: 1.2)
                RoundedRectangle(cornerRadius: height * 0.16, style: .continuous)
                    .fill(fill)
                    .frame(width: max(2, (width - 4) * CGFloat(status.percent) / 100))
                    .padding(2)
                if status.isPluggedIn {
                    Image(systemName: "bolt.fill")
                        .font(.system(size: height * 0.62, weight: .bold))
                        .foregroundStyle(.white)
                        .shadow(color: .black.opacity(0.6), radius: 1)
                        .frame(maxWidth: .infinity)
                }
            }
            .frame(width: width, height: height)
            RoundedRectangle(cornerRadius: 1)
                .fill(tokens.secondaryText.opacity(0.7))
                .frame(width: 2, height: height * 0.4)
        }
        .accessibilityHidden(true)
    }

    private var fill: Color {
        if status.isPluggedIn { return NotchStatusColor.good }
        if status.percent <= 10 { return NotchStatusColor.critical }
        if status.percent <= 20 { return NotchStatusColor.warning }
        return tokens.primaryText.opacity(0.85)
    }
}

// MARK: Bluetooth

private struct DevicesCard: View {
    let devices: [BluetoothDeviceInfo]
    let tokens: ThemeTokens

    var body: some View {
        NotchCard(tokens: tokens) {
            VStack(alignment: .leading, spacing: 6) {
                NotchSectionHeader(title: "Bluetooth", symbol: "dot.radiowaves.left.and.right", tokens: tokens)
                if devices.isEmpty {
                    Text("No devices connected. AirPods and other devices show up here, with a pill in the notch when they connect.")
                        .font(.system(size: 10.5))
                        .foregroundStyle(tokens.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    ForEach(devices.prefix(4)) { device in
                        HStack(spacing: 8) {
                            Image(systemName: device.symbol)
                                .font(.system(size: 12, weight: .medium))
                                .frame(width: 18)
                            Text(device.name)
                                .font(.system(size: 11, weight: .medium))
                                .lineLimit(1)
                                .truncationMode(.tail)
                            Spacer(minLength: 6)
                            ForEach(device.batteries, id: \.label) { battery in
                                BatteryChip(battery: battery, tokens: tokens)
                            }
                        }
                    }
                    if devices.count > 4 {
                        Text("+\(devices.count - 4) more").font(.system(size: 10)).foregroundStyle(tokens.secondaryText)
                    }
                }
            }
        }
    }
}

private struct BatteryChip: View {
    let battery: BluetoothDeviceInfo.Battery
    let tokens: ThemeTokens

    var body: some View {
        HStack(spacing: 2) {
            if !battery.label.isEmpty {
                Text(battery.label).foregroundStyle(tokens.secondaryText)
            }
            Text("\(battery.percent)%")
                .foregroundStyle(battery.percent <= 10 ? NotchStatusColor.critical : (battery.percent <= 20 ? NotchStatusColor.warning : tokens.primaryText))
        }
        .font(.system(size: 10, weight: .medium).monospacedDigit())
        .padding(.horizontal, 5)
        .padding(.vertical, 1.5)
        .background(tokens.controlFill, in: Capsule())
    }
}

// MARK: Downloads

private struct DownloadsCard: View {
    let tokens: ThemeTokens

    @Environment(LiveActivitiesStore.self) private var live

    var body: some View {
        NotchCard(tokens: tokens) {
            VStack(alignment: .leading, spacing: 6) {
                NotchSectionHeader(title: "Downloads", symbol: "arrow.down.circle", tokens: tokens) {
                    if !live.downloads.isEmpty {
                        Button("Clear") { live.clearDownloads() }
                            .buttonStyle(.plain)
                            .font(.system(size: 10, weight: .medium))
                    }
                    Button("Open Folder") { NSWorkspace.shared.open(live.downloadsFolder) }
                        .buttonStyle(.plain)
                        .font(.system(size: 10, weight: .medium))
                }
                if live.downloadsUnreadable {
                    Text("NotchDeck can't read your Downloads folder. Allow it in System Settings → Privacy & Security → Files & Folders.")
                        .font(.system(size: 10.5))
                        .foregroundStyle(tokens.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                } else if live.downloads.isEmpty {
                    Text("New downloads appear here, ready to drag into any app, AirDrop, or keep in the File Tray.")
                        .font(.system(size: 10.5))
                        .foregroundStyle(tokens.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    ForEach(live.downloads.prefix(3)) { item in
                        DownloadRow(item: item, tokens: tokens)
                    }
                }
            }
        }
    }
}

private struct DownloadRow: View {
    let item: DownloadItem
    let tokens: ThemeTokens

    @Environment(LiveActivitiesStore.self) private var live
    @Environment(FileTrayStore.self) private var tray
    @Environment(SettingsStore.self) private var settings
    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 8) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: item.url.path))
                .resizable()
                .frame(width: 22, height: 22)
            VStack(alignment: .leading, spacing: 0) {
                Text(item.name)
                    .font(.system(size: 11, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(detail)
                    .font(.system(size: 9.5).monospacedDigit())
                    .foregroundStyle(tokens.secondaryText)
            }
            Spacer(minLength: 6)
            NotchIconButton(symbol: "airplayaudio", help: "AirDrop", tokens: tokens) {
                NSSharingService(named: .sendViaAirDrop)?.perform(withItems: [item.url])
            }
            if settings.enabledModules.contains(.fileTray) {
                NotchIconButton(symbol: "tray.and.arrow.down", help: "Add to File Tray", tokens: tokens) {
                    tray.add(fileURLs: [item.url])
                }
            }
            NotchIconButton(symbol: "magnifyingglass", help: "Show in Finder", tokens: tokens) {
                NSWorkspace.shared.activateFileViewerSelecting([item.url])
            }
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 2)
        .background(isHovering ? tokens.controlFill : .clear, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
        .onTapGesture(count: 2) { NSWorkspace.shared.open(item.url) }
        .onDrag { NSItemProvider(contentsOf: item.url) ?? NSItemProvider() }
        .contextMenu {
            Button("Open") { NSWorkspace.shared.open(item.url) }
            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([item.url]) }
            Divider()
            Button("Remove from List") { live.removeDownload(item) }
        }
        .help("Drag to use \(item.name) anywhere. Double-click to open.")
    }

    private var detail: String {
        let size = item.byteCount.map { $0.formatted(.byteCount(style: .file)) }
        let time = item.date.formatted(.relative(presentation: .named))
        return [size, time].compactMap { $0 }.joined(separator: " · ")
    }
}
