import Darwin
import Foundation
import IOKit

// MARK: - Snapshot

nonisolated enum CoreKind: String, Sendable { case efficiency, performance }

nonisolated struct ClusterStats: Equatable, Sendable {
    var kind: CoreKind
    /// Per-core usage (0…1), in logical-CPU order.
    var coreUsage: [Double]
    /// Average active frequency (MHz) from IOReport residency, if available.
    var frequencyMHz: Double?

    var usage: Double { coreUsage.isEmpty ? 0 : coreUsage.reduce(0, +) / Double(coreUsage.count) }
}

nonisolated enum MemoryPressure: Int, Sendable {
    case normal = 1, warning = 2, critical = 4
}

/// One reading of the whole machine. `nil` means "not available on this Mac", never zero.
nonisolated struct SystemSnapshot: Equatable, Sendable {
    var date: Date
    var cpuUsage: Double
    var clusters: [ClusterStats]
    var gpuUsage: Double?
    var gpuFrequencyMHz: Double?
    var gpuPowerWatts: Double?
    var cpuPowerWatts: Double?
    var anePowerWatts: Double?
    var memoryUsed: UInt64
    var memoryTotal: UInt64
    var swapUsed: UInt64
    var memoryPressure: MemoryPressure
    var thermalState: ProcessInfo.ThermalState

    var memoryFraction: Double { memoryTotal == 0 ? 0 : Double(memoryUsed) / Double(memoryTotal) }
}

// MARK: - CPU usage

nonisolated struct CPUTicks: Equatable, Sendable {
    var busy: UInt64
    var total: UInt64
}

nonisolated enum CPUUsage {
    /// Per-core cumulative ticks (user + system + nice = busy).
    static func ticks() -> [CPUTicks] {
        var cpuCount: natural_t = 0
        var info: processor_info_array_t?
        var infoCount: mach_msg_type_number_t = 0
        guard host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO, &cpuCount, &info, &infoCount) == KERN_SUCCESS,
              let info else { return [] }
        defer {
            vm_deallocate(mach_task_self_, vm_address_t(bitPattern: info), vm_size_t(infoCount) * vm_size_t(MemoryLayout<integer_t>.stride))
        }
        return (0..<Int(cpuCount)).map { cpu in
            let base = Int(CPU_STATE_MAX) * cpu
            let user = UInt64(UInt32(bitPattern: info[base + Int(CPU_STATE_USER)]))
            let system = UInt64(UInt32(bitPattern: info[base + Int(CPU_STATE_SYSTEM)]))
            let nice = UInt64(UInt32(bitPattern: info[base + Int(CPU_STATE_NICE)]))
            let idle = UInt64(UInt32(bitPattern: info[base + Int(CPU_STATE_IDLE)]))
            return CPUTicks(busy: user + system + nice, total: user + system + nice + idle)
        }
    }

    /// Usage (0…1) per core between two readings.
    static func usage(from old: [CPUTicks], to new: [CPUTicks]) -> [Double] {
        guard old.count == new.count else { return new.map { _ in 0 } }
        return zip(old, new).map { previous, current in
            let total = current.total &- previous.total
            guard total > 0, current.total >= previous.total else { return 0 }
            return min(1, Double(current.busy &- previous.busy) / Double(total))
        }
    }
}

/// Which logical CPUs are efficiency vs performance cores (device tree `cluster-type`),
/// falling back to "efficiency cores first" using `hw.perflevel1.logicalcpu`.
nonisolated enum CPUTopology {
    static func coreKinds(count: Int) -> [CoreKind] {
        if let kinds = fromDeviceTree(), kinds.count == count { return kinds }
        let efficiency = sysctlInt("hw.perflevel1.logicalcpu") ?? 0
        return (0..<count).map { $0 < efficiency ? .efficiency : .performance }
    }

    private static func fromDeviceTree() -> [CoreKind]? {
        let cpus = IORegistryEntryFromPath(kIOMainPortDefault, "IODeviceTree:/cpus")
        guard cpus != 0 else { return nil }
        defer { IOObjectRelease(cpus) }
        var iterator: io_iterator_t = 0
        guard IORegistryEntryGetChildIterator(cpus, kIODeviceTreePlane, &iterator) == KERN_SUCCESS else { return nil }
        defer { IOObjectRelease(iterator) }
        var byID: [Int: CoreKind] = [:]
        while case let cpu = IOIteratorNext(iterator), cpu != 0 {
            defer { IOObjectRelease(cpu) }
            guard let typeData = property(cpu, "cluster-type") as? Data,
                  let id = integer(property(cpu, "logical-cpu-id")) else { continue }
            byID[id] = typeData.first == UInt8(ascii: "E") ? .efficiency : .performance
        }
        guard !byID.isEmpty else { return nil }
        return byID.keys.sorted().map { byID[$0]! }
    }

    static func property(_ entry: io_registry_entry_t, _ key: String) -> Any? {
        IORegistryEntryCreateCFProperty(entry, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
    }

    static func integer(_ value: Any?) -> Int? {
        if let number = value as? NSNumber { return number.intValue }
        if let data = value as? Data, !data.isEmpty {
            return data.prefix(8).enumerated().reduce(0) { $0 | Int($1.element) << (8 * $1.offset) }
        }
        return nil
    }

    static func sysctlInt(_ name: String) -> Int? {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        return sysctlbyname(name, &value, &size, nil, 0) == 0 ? Int(value) : nil
    }
}

// MARK: - Memory

nonisolated enum MemoryStats {
    static func read() -> (used: UInt64, total: UInt64, swapUsed: UInt64, pressure: MemoryPressure) {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        var total: UInt64 = 0
        var size = MemoryLayout<UInt64>.size
        sysctlbyname("hw.memsize", &total, &size, nil, 0)

        var used: UInt64 = 0
        if result == KERN_SUCCESS {
            // Activity Monitor's "Memory Used": app memory (internal − purgeable) + wired + compressed.
            let pageSize = UInt64(getpagesize())
            let app = UInt64(stats.internal_page_count) &- UInt64(stats.purgeable_count)
            used = (app + UInt64(stats.wire_count) + UInt64(stats.compressor_page_count)) * pageSize
        }

        var swap = xsw_usage()
        var swapSize = MemoryLayout<xsw_usage>.size
        let swapUsed = sysctlbyname("vm.swapusage", &swap, &swapSize, nil, 0) == 0 ? swap.xsu_used : 0

        let level = CPUTopology.sysctlInt("kern.memorystatus_vm_pressure_level") ?? 1
        return (min(used, total), total, swapUsed, MemoryPressure(rawValue: level) ?? .normal)
    }
}

// MARK: - GPU utilization (IOKit)

nonisolated enum GPUStats {
    /// "Device Utilization %" from the GPU's IOAccelerator `PerformanceStatistics` (0…1).
    static func utilization() -> Double? {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOAccelerator"), &iterator) == KERN_SUCCESS else { return nil }
        defer { IOObjectRelease(iterator) }
        while case let service = IOIteratorNext(iterator), service != 0 {
            defer { IOObjectRelease(service) }
            if let stats = CPUTopology.property(service, "PerformanceStatistics") as? [String: Any],
               let percent = (stats["Device Utilization %"] as? NSNumber)?.doubleValue {
                return min(1, max(0, percent / 100))
            }
        }
        return nil
    }
}

// MARK: - IOReport (power + frequency)

/// Apple's IOReport counters: what macmon reads, without root. Loaded at runtime; if anything is
/// missing on a given macOS, every derived value is just nil.
nonisolated final class IOReportSampler {
    private typealias CopyChannelsInGroup = @convention(c) (CFString?, CFString?, UInt64, UInt64, UInt64) -> Unmanaged<CFDictionary>?
    private typealias CreateSubscription = @convention(c) (UnsafeMutableRawPointer?, CFMutableDictionary, UnsafeMutablePointer<Unmanaged<CFMutableDictionary>?>, UInt64, CFTypeRef?) -> OpaquePointer?
    private typealias CreateSamples = @convention(c) (OpaquePointer, CFMutableDictionary, CFTypeRef?) -> Unmanaged<CFDictionary>?
    private typealias CreateSamplesDelta = @convention(c) (CFDictionary, CFDictionary, CFTypeRef?) -> Unmanaged<CFDictionary>?
    private typealias GetString = @convention(c) (CFDictionary) -> Unmanaged<CFString>?
    private typealias SimpleGetInteger = @convention(c) (CFDictionary, Int32) -> Int64
    private typealias StateGetCount = @convention(c) (CFDictionary) -> Int32
    private typealias StateGetName = @convention(c) (CFDictionary, Int32) -> Unmanaged<CFString>?
    private typealias StateGetResidency = @convention(c) (CFDictionary, Int32) -> Int64

    private struct API {
        let createSamples: CreateSamples
        let delta: CreateSamplesDelta
        let group: GetString
        let name: GetString
        let unit: GetString
        let integer: SimpleGetInteger
        let stateCount: StateGetCount
        let stateName: StateGetName
        let residency: StateGetResidency
    }

    struct Reading: Equatable {
        var cpuWatts: Double?
        var gpuWatts: Double?
        var aneWatts: Double?
        var eFrequencyMHz: Double?
        var pFrequencyMHz: Double?
        var gpuFrequencyMHz: Double?
    }

    private var api: API?
    private var subscription: OpaquePointer?
    private var channels: CFMutableDictionary?
    private var previous: (sample: CFDictionary, date: Date)?
    private let tables = FrequencyTables.read()

    init() {
        guard let handle = dlopen("/usr/lib/libIOReport.dylib", RTLD_NOW) else { return }
        func load<T>(_ name: String, _: T.Type) -> T? {
            dlsym(handle, name).map { unsafeBitCast($0, to: T.self) }
        }
        guard let copy = load("IOReportCopyChannelsInGroup", CopyChannelsInGroup.self),
              let subscribe = load("IOReportCreateSubscription", CreateSubscription.self),
              let createSamples = load("IOReportCreateSamples", CreateSamples.self),
              let delta = load("IOReportCreateSamplesDelta", CreateSamplesDelta.self),
              let group = load("IOReportChannelGetGroup", GetString.self),
              let name = load("IOReportChannelGetChannelName", GetString.self),
              let unit = load("IOReportChannelGetUnitLabel", GetString.self),
              let integer = load("IOReportSimpleGetIntegerValue", SimpleGetInteger.self),
              let stateCount = load("IOReportStateGetCount", StateGetCount.self),
              let stateName = load("IOReportStateGetNameForIndex", StateGetName.self),
              let residency = load("IOReportStateGetResidency", StateGetResidency.self) else { return }

        let merged = NSMutableDictionary()
        var all: [Any] = []
        for (group, subgroup) in [("Energy Model", nil), ("CPU Stats", "CPU Complex Performance States"), ("GPU Stats", "GPU Performance States")] as [(String, String?)] {
            guard let found = copy(group as CFString, subgroup as CFString?, 0, 0, 0)?.takeRetainedValue() as? [String: Any],
                  let list = found["IOReportChannels"] as? [Any] else { continue }
            all += list
            if merged["QueryOpts"] == nil, let options = found["QueryOpts"] { merged["QueryOpts"] = options }
        }
        guard !all.isEmpty else { return }
        merged["IOReportChannels"] = all

        var subscribed: Unmanaged<CFMutableDictionary>?
        guard let subscription = subscribe(nil, merged as CFMutableDictionary, &subscribed, 0, nil),
              let subscribedChannels = subscribed?.takeRetainedValue() else { return }
        self.subscription = subscription
        self.channels = subscribedChannels
        api = API(createSamples: createSamples, delta: delta, group: group, name: name, unit: unit,
                  integer: integer, stateCount: stateCount, stateName: stateName, residency: residency)
    }

    var isAvailable: Bool { api != nil }

    func read() -> Reading? {
        guard let api, let subscription, let channels,
              let sample = api.createSamples(subscription, channels, nil)?.takeRetainedValue() else { return nil }
        let now = Date()
        defer { previous = (sample, now) }
        guard let previous, let delta = api.delta(previous.sample, sample, nil)?.takeRetainedValue() as? [String: Any],
              let items = delta["IOReportChannels"] as? [CFDictionary] else { return nil }
        let seconds = max(now.timeIntervalSince(previous.date), 0.001)

        var reading = Reading()
        var cpuJoules = 0.0, gpuJoules = 0.0, aneJoules = 0.0
        var eStates: [[(String, Int64)]] = [], pStates: [[(String, Int64)]] = [], gpuStates: [[(String, Int64)]] = []
        for item in items {
            let group = api.group(item)?.takeUnretainedValue() as String? ?? ""
            let name = api.name(item)?.takeUnretainedValue() as String? ?? ""
            if group == "Energy Model" {
                let joules = Self.joules(api.integer(item, 0), unit: api.unit(item)?.takeUnretainedValue() as String? ?? "")
                if name == "CPU Energy" { cpuJoules += joules }
                else if name == "GPU Energy" { gpuJoules += joules }
                else if name.hasPrefix("ANE") { aneJoules += joules }
            } else {
                let states = (0..<api.stateCount(item)).map { index in
                    ((api.stateName(item, index)?.takeUnretainedValue() as String?) ?? "", api.residency(item, index))
                }
                // One entry per channel: chips with two P clusters report PCPU and PCPU1.
                if name.hasPrefix("ECPU") || name.hasPrefix("EACC") { eStates.append(states) }
                else if name.hasPrefix("PCPU") || name.hasPrefix("PACC") { pStates.append(states) }
                else if name == "GPUPH" { gpuStates.append(states) }
            }
        }
        // A channel that reports nothing (e.g. CPU energy on some M4 / macOS builds) stays nil, not 0 W.
        reading.cpuWatts = cpuJoules > 0 ? cpuJoules / seconds : nil
        reading.gpuWatts = gpuJoules > 0 ? gpuJoules / seconds : (gpuStates.isEmpty ? nil : 0)
        reading.aneWatts = aneJoules > 0 ? aneJoules / seconds : nil
        reading.eFrequencyMHz = Self.averageFrequency(eStates, table: tables.efficiency)
        reading.pFrequencyMHz = Self.averageFrequency(pStates, table: tables.performance)
        reading.gpuFrequencyMHz = Self.averageFrequency(gpuStates, table: tables.gpu)
        return reading
    }

    static func joules(_ value: Int64, unit: String) -> Double {
        switch unit {
        case "mJ": Double(value) / 1e3
        case "uJ", "µJ": Double(value) / 1e6
        case "nJ": Double(value) / 1e9
        default: 0
        }
    }

    /// Residency-weighted average frequency (MHz) over the *active* states of each channel.
    ///
    /// A channel's states are `[IDLE/OFF, s1, s2, …]`. CPU tables list only the active frequencies
    /// (one fewer entry than states), the GPU table also has a 0 entry for OFF (same count), so the
    /// table index is the state index minus the difference in length.
    static func averageFrequency(_ channels: [[(String, Int64)]], table: [Double]) -> Double? {
        guard !table.isEmpty else { return nil }
        let idleNames: Set<String> = ["IDLE", "OFF", "DOWN"]
        var weighted = 0.0, active = 0.0
        for states in channels {
            let offset = states.count - table.count
            guard offset >= 0 else { continue }
            for (index, state) in states.enumerated() where state.1 > 0 && !idleNames.contains(state.0) {
                let entry = index - offset
                guard entry >= 0, entry < table.count, table[entry] > 0 else { continue }
                weighted += Double(state.1) * table[entry]
                active += Double(state.1)
            }
        }
        return active > 0 ? weighted / active : nil
    }
}

/// Per-cluster frequency tables (MHz) from the power manager's `voltage-states*` properties:
/// `voltage-states1-sram` = efficiency cores, `voltage-states5-sram` = performance cores,
/// `voltage-states9` = GPU (CPU tables are in kHz, the GPU table in Hz).
nonisolated struct FrequencyTables: Sendable {
    var efficiency: [Double] = []
    var performance: [Double] = []
    var gpu: [Double] = []

    static func read() -> FrequencyTables {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("AppleARMIODevice"), &iterator) == KERN_SUCCESS else { return FrequencyTables() }
        defer { IOObjectRelease(iterator) }
        while case let service = IOIteratorNext(iterator), service != 0 {
            defer { IOObjectRelease(service) }
            var name = [CChar](repeating: 0, count: 128)
            guard IORegistryEntryGetName(service, &name) == KERN_SUCCESS,
                  String(decoding: name.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self) == "pmgr" else { continue }
            func table(_ key: String) -> [Double] {
                guard let data = CPUTopology.property(service, key) as? Data else { return [] }
                return decode(data)
            }
            return FrequencyTables(
                efficiency: table("voltage-states1-sram"),
                performance: table("voltage-states5-sram"),
                gpu: table("voltage-states9")
            )
        }
        return FrequencyTables()
    }

    /// Entries are (frequency, voltage) UInt32 pairs. Values above 10,000,000 are Hz, otherwise kHz.
    static func decode(_ data: Data) -> [Double] {
        stride(from: 0, to: data.count - 7, by: 8).map { offset in
            let raw = data[data.startIndex + offset..<data.startIndex + offset + 4]
                .enumerated().reduce(UInt32(0)) { $0 | UInt32($1.element) << (8 * $1.offset) }
            return raw > 10_000_000 ? Double(raw) / 1e6 : Double(raw) / 1e3
        }
    }
}

// MARK: - Sampler

/// Owns the stateful readers. Used from one task at a time (the store's sampling loop).
nonisolated final class SystemSampler: @unchecked Sendable {
    private var previousTicks: [CPUTicks] = []
    private var coreKinds: [CoreKind] = []
    private let ioReport = IOReportSampler()

    func sample() -> SystemSnapshot {
        let ticks = CPUUsage.ticks()
        let usage = previousTicks.isEmpty ? ticks.map { _ in 0.0 } : CPUUsage.usage(from: previousTicks, to: ticks)
        previousTicks = ticks
        if coreKinds.count != ticks.count { coreKinds = CPUTopology.coreKinds(count: ticks.count) }

        let report = ioReport.read()
        var clusters: [ClusterStats] = []
        for kind in [CoreKind.efficiency, .performance] {
            let cores = zip(coreKinds, usage).filter { $0.0 == kind }.map(\.1)
            guard !cores.isEmpty else { continue }
            clusters.append(ClusterStats(
                kind: kind, coreUsage: cores,
                frequencyMHz: kind == .efficiency ? report?.eFrequencyMHz : report?.pFrequencyMHz
            ))
        }
        let memory = MemoryStats.read()
        return SystemSnapshot(
            date: Date(),
            cpuUsage: usage.isEmpty ? 0 : usage.reduce(0, +) / Double(usage.count),
            clusters: clusters,
            gpuUsage: GPUStats.utilization(),
            gpuFrequencyMHz: report?.gpuFrequencyMHz,
            gpuPowerWatts: report?.gpuWatts,
            cpuPowerWatts: report?.cpuWatts,
            anePowerWatts: report?.aneWatts,
            memoryUsed: memory.used,
            memoryTotal: memory.total,
            swapUsed: memory.swapUsed,
            memoryPressure: memory.pressure,
            thermalState: ProcessInfo.processInfo.thermalState
        )
    }
}
