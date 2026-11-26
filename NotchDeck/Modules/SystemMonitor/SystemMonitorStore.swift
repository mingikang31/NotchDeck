import Foundation
import Observation

/// Live CPU / GPU / memory readings for the System tab (asitop / macmon style, no admin rights).
///
/// Samples at the user's chosen rate (Settings → Modules → System Monitor), and only while a
/// System tab is on screen, so it costs nothing when you're not looking. The sparklines always cover
/// the last two minutes, whatever the rate.
@Observable
final class SystemMonitorStore {
    /// Sparkline window, in seconds.
    static let historyWindow: Double = 120

    /// One timestamped reading for a sparkline.
    struct Sample: Equatable, Sendable {
        var date: Date
        var value: Double
    }

    private(set) var latest: SystemSnapshot?
    private(set) var cpuHistory: [Sample] = []
    private(set) var gpuHistory: [Sample] = []
    private(set) var memoryHistory: [Sample] = []

    @ObservationIgnored private let settings: SettingsStore
    @ObservationIgnored private let sampler = SystemSampler()
    @ObservationIgnored private var visibleViews = 0
    @ObservationIgnored private var samplingTask: Task<Void, Never>?

    init(settings: SettingsStore) {
        self.settings = settings
    }

    var interval: Double { settings.systemMonitorInterval }


    func viewAppeared() {
        visibleViews += 1
        guard samplingTask == nil else { return }
        let sampler = sampler
        samplingTask = Task.detached(priority: .utility) { [weak self] in
            while !Task.isCancelled {
                let snapshot = sampler.sample()
                await self?.apply(snapshot)
                // Re-read every tick so a new rate applies immediately.
                let seconds = await self?.interval ?? 1
                try? await Task.sleep(for: .milliseconds(Int(seconds * 1000)))
            }
        }
    }

    func viewDisappeared() {
        visibleViews = max(0, visibleViews - 1)
        guard visibleViews == 0 else { return }
        samplingTask?.cancel()
        samplingTask = nil
    }

    func apply(_ snapshot: SystemSnapshot) {
        latest = snapshot
        Self.append(Sample(date: snapshot.date, value: snapshot.cpuUsage), to: &cpuHistory)
        if let gpu = snapshot.gpuUsage { Self.append(Sample(date: snapshot.date, value: gpu), to: &gpuHistory) }
        Self.append(Sample(date: snapshot.date, value: snapshot.memoryFraction), to: &memoryHistory)
    }

    /// Keeps samples by age, not count, so the window stays two minutes when the rate changes.
    static func append(_ sample: Sample, to history: inout [Sample]) {
        history.append(sample)
        let cutoff = sample.date.addingTimeInterval(-historyWindow - 1)
        if let firstKept = history.firstIndex(where: { $0.date >= cutoff }), firstKept > 0 {
            history.removeFirst(firstKept)
        }
    }
}
