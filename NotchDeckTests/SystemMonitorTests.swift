import Foundation
import Testing
@testable import NotchDeck

struct SystemMonitorMathTests {
    @Test func cpuUsageFromTickDeltas() {
        let old = [CPUTicks(busy: 100, total: 1000), CPUTicks(busy: 500, total: 1000)]
        let new = [CPUTicks(busy: 150, total: 1100), CPUTicks(busy: 500, total: 1100)]
        #expect(CPUUsage.usage(from: old, to: new) == [0.5, 0])
        // A counter that went backwards (core reset) reads 0, not garbage.
        #expect(CPUUsage.usage(from: [CPUTicks(busy: 9, total: 9)], to: [CPUTicks(busy: 1, total: 2)]) == [0])
        // Mismatched core counts (CPU hot-plug) don't crash.
        #expect(CPUUsage.usage(from: old, to: [CPUTicks(busy: 1, total: 2)]) == [0])
    }

    @Test func frequencyTablesDecodeKilohertzAndHertz() {
        func entry(_ value: UInt32) -> [UInt8] {
            (0..<4).map { UInt8((value >> (8 * $0)) & 0xFF) } + [0x16, 0x03, 0, 0] // + a voltage word
        }
        // CPU tables are in kHz (912000 → 912 MHz); the GPU table is in Hz (338000000 → 338 MHz).
        #expect(FrequencyTables.decode(Data(entry(912_000) + entry(4_464_000))) == [912, 4464])
        #expect(FrequencyTables.decode(Data(entry(0) + entry(338_000_000))) == [0, 338])
        #expect(FrequencyTables.decode(Data([1, 2, 3])) == []) // truncated data is ignored
    }

    @Test func clusterFrequencyIsResidencyWeighted() throws {
        // CPU: states [IDLE, f1, f2], table [1000, 2000] (no idle entry).
        let cpu = IOReportSampler.averageFrequency([[("IDLE", 900), ("V0P2", 100), ("V1P1", 300)]], table: [1000, 2000])
        #expect(try #require(cpu) == 1750) // (100×1000 + 300×2000) / 400

        // GPU: states [OFF, P1, P2], table [0, 400, 800] (includes the OFF entry).
        let gpu = IOReportSampler.averageFrequency([[("OFF", 50), ("P1", 10), ("P2", 30)]], table: [0, 400, 800])
        #expect(try #require(gpu) == 700)

        // Two P clusters (PCPU + PCPU1) are averaged together.
        let twoClusters = IOReportSampler.averageFrequency([[("IDLE", 1), ("A", 100)], [("IDLE", 1), ("A", 0)]], table: [3000])
        #expect(twoClusters == 3000)

        // Fully idle → no frequency (not 0 MHz).
        #expect(IOReportSampler.averageFrequency([[("IDLE", 500), ("V0", 0)]], table: [1000]) == nil)
        #expect(IOReportSampler.averageFrequency([[("IDLE", 1), ("V0", 5)]], table: []) == nil)
    }

    @Test func energyUnits() {
        #expect(IOReportSampler.joules(1500, unit: "mJ") == 1.5)
        #expect(IOReportSampler.joules(2_000_000, unit: "uJ") == 2)
        #expect(IOReportSampler.joules(54_870_023, unit: "nJ") == 0.054870023)
        #expect(IOReportSampler.joules(5, unit: "?") == 0)
    }
}

/// Samples the real machine running the tests and checks the numbers are physically sensible.
struct SystemSamplerLiveTests {
    @Test func readingsAreSane() async throws {
        let sampler = SystemSampler()
        _ = sampler.sample()
        try await Task.sleep(for: .milliseconds(400))
        let snapshot = sampler.sample()

        let cores = snapshot.clusters.reduce(0) { $0 + $1.coreUsage.count }
        #expect(cores == ProcessInfo.processInfo.processorCount)
        #expect((0...1).contains(snapshot.cpuUsage))
        #expect(snapshot.clusters.allSatisfy { $0.coreUsage.allSatisfy { (0...1).contains($0) } })
        #expect(snapshot.memoryTotal == ProcessInfo.processInfo.physicalMemory)
        #expect(snapshot.memoryUsed > 0 && snapshot.memoryUsed <= snapshot.memoryTotal)

        #if arch(arm64)
        #expect(Set(snapshot.clusters.map(\.kind)) == [.efficiency, .performance])
        #expect(snapshot.gpuUsage != nil)
        for cluster in snapshot.clusters {
            if let mhz = cluster.frequencyMHz { #expect((300...6000).contains(mhz)) }
        }
        if let watts = snapshot.gpuPowerWatts { #expect((0...200).contains(watts)) }
        #endif
    }
}

struct SystemMonitorSettingsAndLayoutTests {
    @Test func refreshIntervalDefaultsSnapsAndPersists() {
        let name = "NotchDeckMonitor.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        let settings = SettingsStore(defaults: defaults)
        #expect(settings.systemMonitorInterval == 1)
        settings.systemMonitorInterval = 0.7   // not an option: snaps to the nearest (0.5)
        #expect(settings.systemMonitorInterval == 0.5)
        settings.systemMonitorInterval = 0.2   // snaps to the fastest option, 250 ms
        #expect(settings.systemMonitorInterval == 0.25)
        #expect(SettingsStore.systemMonitorIntervals == [0.25, 0.5, 1, 2, 5])
        #expect(SystemMonitorModuleView.intervalLabel(0.25) == "250 ms")
        #expect(settings.systemOverviewStyle == .cards)
        settings.systemOverviewStyle = .meterRows
        #expect(SettingsStore(defaults: defaults).systemOverviewStyle == .meterRows)
        settings.systemMonitorInterval = 5
        #expect(SettingsStore(defaults: defaults).systemMonitorInterval == 5)
        defaults.removePersistentDomain(forName: name)
    }

    @Test func historyKeepsTwoMinutesWhateverTheRate() {
        var history: [SystemMonitorStore.Sample] = []
        let start = Date(timeIntervalSince1970: 1_000)
        // 100 s at 0.5 s, then 100 s at 5 s.
        for i in 0..<200 { SystemMonitorStore.append(.init(date: start.addingTimeInterval(Double(i) * 0.5), value: 0.1), to: &history) }
        let switchTime = start.addingTimeInterval(100)
        for i in 1...20 { SystemMonitorStore.append(.init(date: switchTime.addingTimeInterval(Double(i) * 5), value: 0.9), to: &history) }
        let span = history.last!.date.timeIntervalSince(history.first!.date)
        #expect(span <= SystemMonitorStore.historyWindow + 1)
        #expect(span >= SystemMonitorStore.historyWindow - 5)
        #expect(history.last?.value == 0.9)
    }

    private let geometry = NotchGeometry.compute(
        screenFrame: CGRect(x: 0, y: 0, width: 1512, height: 982),
        visibleFrame: CGRect(x: 0, y: 61, width: 1512, height: 888),
        safeAreaTop: 32,
        auxiliaryTopLeft: CGRect(x: 0, y: 950, width: 663.5, height: 32),
        auxiliaryTopRight: CGRect(x: 848.5, y: 950, width: 663.5, height: 32),
        preset: .medium
    )

    @Test func fittedLayoutHugsMeasuredContent() {
        let fitted = ExpandedLayout.fitted(286.4)
        #expect(geometry.metrics(for: .expanded, layout: fitted).bodySize.height == 287)
        #expect(geometry.metrics(for: .expanded, layout: fitted).bodySize.width == geometry.metrics(for: .expanded).bodySize.width)
        let panel = geometry.panelFrame(for: fitted)
        #expect(panel.maxY == geometry.panelFrame.maxY)                 // same top edge
        #expect(panel.height == 287 + NotchGeometry.shadowPadding)     // no strip below the shape
        #expect(panel.contains(geometry.shapeRect(for: .expanded, layout: fitted)))
        // Clamped between a small minimum and the tall layout.
        #expect(geometry.metrics(for: .expanded, layout: .fitted(5_000)).bodySize.height == geometry.metrics(for: .expanded, layout: .tall).bodySize.height)
        #expect(geometry.metrics(for: .expanded, layout: .fitted(10)).bodySize.height == geometry.cutout.height + 60)
    }

    @Test func systemTabUsesFittedLayoutOnceMeasured() {
        #expect(ExpandedLayout.forModule(.systemMonitor, hasPendingApproval: false) == .tall) // before measuring
        #expect(ExpandedLayout.forModule(.systemMonitor, hasPendingApproval: false, fittedHeight: 290) == .fitted(290))
        #expect(ExpandedLayout.forModule(.aiChat, hasPendingApproval: false, fittedHeight: 290) == .tall)
        #expect(ExpandedLayout.forModule(.media, hasPendingApproval: false) == .standard)
    }
}
