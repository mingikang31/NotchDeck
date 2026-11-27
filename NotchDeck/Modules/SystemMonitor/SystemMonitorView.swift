import SwiftUI

/// Colors for the System tab (dark surfaces only; validated for contrast on the notch's black and
/// dark-glass surfaces). One accent hue for magnitude; status colors only for real states, and
/// always next to an icon + label.
extension EnvironmentValues {
    /// The System tab's magnitude color (Settings → Modules → System Monitor → Color).
    @Entry var monitorAccent = AccentColorChoice.blue.color
}

private enum MonitorPalette {
    static let trend = Color.white.opacity(0.38)     // de-emphasized sparkline history
    static let primaryInk = Color(hex: 0xEFEFEF)
    static let secondaryInk = Color(hex: 0x9C9C9C)
    static let good = Color(hex: 0x0AAC23)
    static let warning = Color(hex: 0xFBB315)
    static let serious = Color(hex: 0xF18A59)
    static let critical = Color(hex: 0xDC3C3D)
}

private extension Color {
    init(hex: UInt32) {
        self.init(red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255, blue: Double(hex & 0xFF) / 255)
    }
}

/// Expanded System tab: CPU / GPU / memory tiles with 2-minute sparklines, per-core bars by cluster,
/// power and thermal readouts.
struct SystemMonitorModuleView: View {
    let tokens: ThemeTokens

    @Environment(SystemMonitorStore.self) private var monitor
    @Environment(SettingsStore.self) private var settings

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let snapshot = monitor.latest {
                OverviewSection(style: settings.systemOverviewStyle, metrics: overviewMetrics(snapshot))

                HStack(alignment: .top, spacing: 14) {
                    ForEach(snapshot.clusters, id: \.kind) { cluster in
                        ClusterBars(cluster: cluster)
                    }
                }

                HStack(spacing: 14) {
                    PowerReadout(label: "CPU", watts: snapshot.cpuPowerWatts,
                                 unavailableHelp: "This Mac doesn't expose CPU energy counters to apps without admin rights.")
                    PowerReadout(label: "GPU", watts: snapshot.gpuPowerWatts, unavailableHelp: "GPU power isn't available on this Mac.")
                    PowerReadout(label: "Neural Engine", watts: snapshot.anePowerWatts, unavailableHelp: "Neural Engine power isn't available on this Mac.")
                    Spacer(minLength: 8)
                    StatusBadge(memoryPressure: snapshot.memoryPressure)
                    StatusBadge(thermal: snapshot.thermalState)
                }
            } else {
                Text("Measuring…")
                    .font(.system(size: 12))
                    .foregroundStyle(MonitorPalette.secondaryInk)
                    .frame(maxWidth: .infinity, minHeight: 200)
            }
        }
        // Usage fills, meters, graphs and sparkline "now" use the color chosen in Settings.
        .environment(\.monitorAccent, settings.systemMonitorAccent.color)
        .onAppear { monitor.viewAppeared() }
        .onDisappear { monitor.viewDisappeared() }
    }

    private func percent(_ value: Double) -> String { "\(Int((value * 100).rounded()))%" }

    /// The three headline metrics, independent of how the chosen style draws them.
    private func overviewMetrics(_ snapshot: SystemSnapshot) -> [OverviewMetric] {
        [
            OverviewMetric(label: "CPU", value: percent(snapshot.cpuUsage), detail: cpuDetail(snapshot),
                           fraction: snapshot.cpuUsage, history: monitor.cpuHistory),
            OverviewMetric(label: "GPU", value: snapshot.gpuUsage.map(percent) ?? "—", detail: gpuDetail(snapshot),
                           fraction: snapshot.gpuUsage, history: monitor.gpuHistory),
            OverviewMetric(label: "Memory", value: gigabytes(snapshot.memoryUsed),
                           detail: "of \(gigabytes(snapshot.memoryTotal)) · swap \(gigabytes(snapshot.swapUsed))",
                           fraction: snapshot.memoryFraction, history: monitor.memoryHistory),
        ]
    }

    static func intervalLabel(_ seconds: Double) -> String {
        seconds < 1 ? "\(Int((seconds * 1000).rounded())) ms" : "\(Int(seconds)) s"
    }

    private func gigabytes(_ bytes: UInt64) -> String {
        let gb = Double(bytes) / 1_073_741_824
        return gb >= 10 ? String(format: "%.0f GB", gb) : String(format: "%.1f GB", gb)
    }

    private func frequency(_ mhz: Double?) -> String? {
        guard let mhz else { return nil }
        return mhz >= 1000 ? String(format: "%.2f GHz", mhz / 1000) : String(format: "%.0f MHz", mhz)
    }

    private func cpuDetail(_ snapshot: SystemSnapshot) -> String {
        let parts = snapshot.clusters.compactMap { cluster -> String? in
            frequency(cluster.frequencyMHz).map { "\(cluster.kind == .performance ? "P" : "E") \($0)" }
        }
        return parts.isEmpty ? "\(snapshot.clusters.reduce(0) { $0 + $1.coreUsage.count }) cores" : parts.joined(separator: " · ")
    }

    private func gpuDetail(_ snapshot: SystemSnapshot) -> String {
        [frequency(snapshot.gpuFrequencyMHz), snapshot.gpuPowerWatts.map { String(format: "%.1f W", $0) }]
            .compactMap { $0 }.joined(separator: " · ")
    }
}

// MARK: - Overview (the three top components), in four styles

/// One headline metric. `fraction` (0…1) drives meters; nil = unavailable (drawn as "—", never 0).
struct OverviewMetric: Identifiable {
    var label: String
    var value: String
    var detail: String
    var fraction: Double?
    var history: [SystemMonitorStore.Sample]

    var id: String { label }
}

private struct OverviewSection: View {
    let style: SystemOverviewStyle
    let metrics: [OverviewMetric]

    var body: some View {
        switch style {
        case .cards:
            HStack(spacing: 8) {
                ForEach(metrics) { StatTile(label: $0.label, value: $0.value, detail: $0.detail, history: $0.history) }
            }
            .frame(height: 104)
        case .meterRows:
            VStack(spacing: 7) {
                ForEach(metrics) { MeterRow(metric: $0) }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 9)
            .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.white.opacity(0.10)))
        case .areaGraphs:
            HStack(spacing: 8) {
                ForEach(metrics) { AreaTile(metric: $0) }
            }
            .frame(height: 112)
        case .minimal:
            HStack(alignment: .top, spacing: 0) {
                ForEach(Array(metrics.enumerated()), id: \.element.id) { index, metric in
                    if index > 0 {
                        Rectangle().fill(Color.white.opacity(0.10)).frame(width: 1).padding(.vertical, 2)
                    }
                    MinimalColumn(metric: metric)
                        .padding(.leading, index == 0 ? 0 : 14)
                        .padding(.trailing, 14)
                }
            }
        }
    }
}

/// Horizontal meter with a same-hue track, 4 px rounded fill anchored at the leading edge.
private struct HorizontalMeter: View {
    @Environment(\.monitorAccent) private var accent
    let fraction: Double?
    var height: CGFloat = 8

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(accent.opacity(0.18))
                if let fraction {
                    Capsule()
                        .fill(accent)
                        .frame(width: max(height, proxy.size.width * CGFloat(min(max(fraction, 0), 1))))
                }
            }
        }
        .frame(height: height)
        .animation(.easeOut(duration: 0.35), value: fraction)
    }
}

/// Meter row: name · meter · value · details · mini trend (all rows aligned on the same columns).
private struct MeterRow: View {
    let metric: OverviewMetric

    var body: some View {
        HStack(spacing: 10) {
            Text(metric.label)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(MonitorPalette.secondaryInk)
                .frame(width: 52, alignment: .leading)
            HorizontalMeter(fraction: metric.fraction)
                .frame(minWidth: 120)
            Text(metric.value)
                .font(.system(size: 13, weight: .semibold).monospacedDigit())
                .foregroundStyle(metric.fraction == nil ? MonitorPalette.secondaryInk : MonitorPalette.primaryInk)
                .contentTransition(.numericText())
                .frame(width: 60, alignment: .trailing)
            Text(metric.detail.isEmpty ? " " : metric.detail)
                .font(.system(size: 10).monospacedDigit())
                .foregroundStyle(MonitorPalette.secondaryInk)
                .lineLimit(1)
                .frame(width: 150, alignment: .leading)
            Sparkline(samples: metric.history)
                .frame(width: 64, height: 16)
        }
        .frame(height: 20)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(metric.label) \(metric.value), \(metric.detail)")
    }
}

/// Tile whose lower half is the last two minutes as a filled area graph.
private struct AreaTile: View {
    let metric: OverviewMetric

    var body: some View {
        ZStack(alignment: .topLeading) {
            AreaGraph(samples: metric.history)
                .padding(.top, 46)
            VStack(alignment: .leading, spacing: 1) {
                HStack(alignment: .firstTextBaseline) {
                    Text(metric.label)
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(MonitorPalette.secondaryInk)
                    Spacer(minLength: 4)
                    Text(metric.value)
                        .font(.system(size: 18, weight: .semibold).monospacedDigit())
                        .foregroundStyle(metric.fraction == nil ? MonitorPalette.secondaryInk : MonitorPalette.primaryInk)
                        .contentTransition(.numericText())
                }
                Text(metric.detail.isEmpty ? " " : metric.detail)
                    .font(.system(size: 10).monospacedDigit())
                    .foregroundStyle(MonitorPalette.secondaryInk)
                    .lineLimit(1)
            }
            .padding(.horizontal, 10)
            .padding(.top, 8)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.white.opacity(0.10)))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(metric.label) \(metric.value), \(metric.detail)")
    }
}

/// Single-series area: a 2 px accent line over a soft fill of the same hue, placed by time.
private struct AreaGraph: View {
    @Environment(\.monitorAccent) private var accent
    let samples: [SystemMonitorStore.Sample]

    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            let now = samples.last?.date ?? Date()
            let window = SystemMonitorStore.historyWindow
            let points = samples.compactMap { sample -> CGPoint? in
                let age = now.timeIntervalSince(sample.date)
                guard age <= window else { return nil }
                return CGPoint(x: size.width * CGFloat(1 - age / window),
                               y: size.height - CGFloat(min(max(sample.value, 0), 1)) * (size.height - 3))
            }
            if let first = points.first, let last = points.last {
                Path { path in
                    path.move(to: CGPoint(x: first.x, y: size.height))
                    points.forEach { path.addLine(to: $0) }
                    path.addLine(to: CGPoint(x: last.x, y: size.height))
                    path.closeSubpath()
                }
                .fill(LinearGradient(colors: [accent.opacity(0.32), accent.opacity(0.04)],
                                     startPoint: .top, endPoint: .bottom))
                Path { path in
                    path.move(to: first)
                    points.dropFirst().forEach { path.addLine(to: $0) }
                }
                .stroke(accent, style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
            }
        }
        .accessibilityHidden(true)
    }
}

/// Big number, details, and a slim meter: no box, no graph.
private struct MinimalColumn: View {
    let metric: OverviewMetric

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(metric.label)
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(MonitorPalette.secondaryInk)
            Text(metric.value)
                .font(.system(size: 26, weight: .semibold).monospacedDigit())
                .foregroundStyle(metric.fraction == nil ? MonitorPalette.secondaryInk : MonitorPalette.primaryInk)
                .contentTransition(.numericText())
            Text(metric.detail.isEmpty ? " " : metric.detail)
                .font(.system(size: 10).monospacedDigit())
                .foregroundStyle(MonitorPalette.secondaryInk)
                .lineLimit(1)
            HorizontalMeter(fraction: metric.fraction, height: 4)
                .padding(.top, 4)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(metric.label) \(metric.value), \(metric.detail)")
    }
}

/// Stat tile: label · value · detail · 2-minute sparkline (history de-emphasized, "now" in the accent).
private struct StatTile: View {
    let label: String
    let value: String
    let detail: String
    let history: [SystemMonitorStore.Sample]

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(MonitorPalette.secondaryInk)
            Text(value)
                .font(.system(size: 22, weight: .semibold).monospacedDigit())
                .foregroundStyle(value == "—" ? MonitorPalette.secondaryInk : MonitorPalette.primaryInk)
                .contentTransition(.numericText())
            Text(detail.isEmpty ? " " : detail)
                .font(.system(size: 10).monospacedDigit())
                .foregroundStyle(MonitorPalette.secondaryInk)
                .lineLimit(1)
            Sparkline(samples: history)
                .frame(maxHeight: .infinity)
                .padding(.top, 2)
        }
        .padding(10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.white.opacity(0.10)))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(label) \(value), \(detail)")
    }
}

/// 0…1 values over a fixed 2-minute window, placed by time ("now" at the right edge), so the
/// window stays honest whatever the refresh rate, or if it changed mid-way.
private struct Sparkline: View {
    @Environment(\.monitorAccent) private var accent
    let samples: [SystemMonitorStore.Sample]

    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            let now = samples.last?.date ?? Date()
            let window = SystemMonitorStore.historyWindow
            let points = samples.compactMap { sample -> CGPoint? in
                let age = now.timeIntervalSince(sample.date)
                guard age <= window else { return nil }
                return CGPoint(
                    x: size.width * CGFloat(1 - age / window),
                    y: size.height - 1 - CGFloat(min(max(sample.value, 0), 1)) * (size.height - 2)
                )
            }
            ZStack {
                Path { path in
                    guard let first = points.first else { return }
                    path.move(to: first)
                    points.dropFirst().forEach { path.addLine(to: $0) }
                }
                .stroke(MonitorPalette.trend, style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))

                if points.count >= 2 {
                    Path { path in
                        path.move(to: points[points.count - 2])
                        path.addLine(to: points[points.count - 1])
                    }
                    .stroke(accent, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                }
                if let last = points.last {
                    Circle()
                        .fill(accent)
                        .overlay(Circle().strokeBorder(Color.black, lineWidth: 2)) // surface ring
                        .frame(width: 8, height: 8)
                        .position(last)
                }
            }
        }
        .accessibilityHidden(true)
    }
}

/// Per-core meters for one cluster, with the cluster's average and frequency.
private struct ClusterBars: View {
    let cluster: ClusterStats

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                Text(cluster.kind == .performance ? "Performance cores" : "Efficiency cores")
                    .foregroundStyle(MonitorPalette.secondaryInk)
                Text("\(Int((cluster.usage * 100).rounded()))%")
                    .foregroundStyle(MonitorPalette.primaryInk)
                if let mhz = cluster.frequencyMHz {
                    Text(mhz >= 1000 ? String(format: "%.2f GHz", mhz / 1000) : String(format: "%.0f MHz", mhz))
                        .foregroundStyle(MonitorPalette.secondaryInk)
                }
            }
            .font(.system(size: 10, weight: .medium).monospacedDigit())

            HStack(alignment: .bottom, spacing: 3) {
                ForEach(Array(cluster.coreUsage.enumerated()), id: \.offset) { index, usage in
                    CoreMeter(usage: usage)
                        .help("Core \(index + 1): \(Int((usage * 100).rounded()))%")
                }
            }
            .frame(height: 46)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

/// Vertical meter: same-hue track, 4 px rounded fill anchored at the baseline.
private struct CoreMeter: View {
    @Environment(\.monitorAccent) private var accent
    let usage: Double

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .bottom) {
                RoundedRectangle(cornerRadius: 4, style: .continuous).fill(accent.opacity(0.18))
                UnevenRoundedRectangle(cornerRadii: .init(topLeading: 4, bottomLeading: 2, bottomTrailing: 2, topTrailing: 4), style: .continuous)
                    .fill(accent)
                    .frame(height: max(2, proxy.size.height * CGFloat(min(max(usage, 0), 1))))
            }
        }
        .frame(maxWidth: 22)
        .animation(.easeOut(duration: 0.35), value: usage)
    }
}

private struct PowerReadout: View {
    let label: String
    let watts: Double?
    let unavailableHelp: String

    var body: some View {
        HStack(spacing: 4) {
            Text(label).foregroundStyle(MonitorPalette.secondaryInk)
            Text(watts.map { String(format: "%.2f W", $0) } ?? "—")
                .foregroundStyle(watts == nil ? MonitorPalette.secondaryInk : MonitorPalette.primaryInk)
        }
        .font(.system(size: 10.5, weight: .medium).monospacedDigit())
        .help(watts == nil ? unavailableHelp : "\(label) power draw, averaged over the last second")
    }
}

/// Status chip: icon + label + status color (never color alone).
private struct StatusBadge: View {
    let symbol: String
    let text: String
    let color: Color

    init(memoryPressure: MemoryPressure) {
        switch memoryPressure {
        case .normal: (symbol, text, color) = ("checkmark.circle.fill", "Memory OK", MonitorPalette.good)
        case .warning: (symbol, text, color) = ("exclamationmark.triangle.fill", "Memory pressure", MonitorPalette.warning)
        case .critical: (symbol, text, color) = ("xmark.octagon.fill", "Memory critical", MonitorPalette.critical)
        }
    }

    init(thermal: ProcessInfo.ThermalState) {
        switch thermal {
        case .nominal: (symbol, text, color) = ("thermometer.low", "Thermal OK", MonitorPalette.good)
        case .fair: (symbol, text, color) = ("thermometer.medium", "Warm", MonitorPalette.warning)
        case .serious: (symbol, text, color) = ("thermometer.high", "Hot, throttling", MonitorPalette.serious)
        case .critical: (symbol, text, color) = ("flame.fill", "Critical heat", MonitorPalette.critical)
        @unknown default: (symbol, text, color) = ("thermometer.medium", "Thermal unknown", MonitorPalette.secondaryInk)
        }
    }

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: symbol).foregroundStyle(color)
            Text(text).foregroundStyle(MonitorPalette.primaryInk)
        }
        .font(.system(size: 10.5, weight: .medium))
    }
}
