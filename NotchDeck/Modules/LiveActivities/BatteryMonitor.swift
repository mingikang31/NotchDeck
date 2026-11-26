import Foundation
import IOKit
import IOKit.ps

/// One reading of the internal battery.
nonisolated struct BatteryStatus: Equatable, Sendable {
    var percent: Int
    /// On AC power (adapter attached), whether or not it is charging right now.
    var isPluggedIn: Bool
    var isCharging: Bool
    var isCharged: Bool
    var minutesToEmpty: Int?
    var minutesToFull: Int?
    /// The adapter's rating, e.g. 96 W.
    var adapterWatts: Int?
    /// Power flowing into (+) or out of (−) the battery, from the battery's own voltage × current.
    var batteryWatts: Double?
    var cycleCount: Int?
    /// Full-charge capacity as a share of the design capacity.
    var healthPercent: Int?

    /// "Charging", "On battery", … for the card's status line.
    var stateDescription: String {
        if isPluggedIn {
            if isCharging { return "Charging" }
            return isCharged || percent >= 100 ? "Charged" : "Plugged in, not charging"
        }
        return "On battery"
    }

    /// "1h 10m to full" / "4h 32m left", or nil while macOS is still estimating.
    var timeDescription: String? {
        if isPluggedIn, isCharging, let minutes = minutesToFull { return "\(Self.duration(minutes)) to full" }
        if !isPluggedIn, let minutes = minutesToEmpty { return "\(Self.duration(minutes)) left" }
        return nil
    }

    static func duration(_ minutes: Int) -> String {
        minutes >= 60 ? "\(minutes / 60)h \(minutes % 60)m" : "\(minutes)m"
    }
}

/// Watches the internal battery via IOPowerSources notifications (no polling, no permission).
final class BatteryMonitor {
    /// Low-battery warnings fire when the charge drops through each of these.
    nonisolated static let lowThresholds = [20, 10, 5]

    var onChange: ((BatteryStatus?) -> Void)?
    private(set) var status: BatteryStatus?
    private var runLoopSource: CFRunLoopSource?

    /// False on desktops; the battery card and pills are hidden then.
    static var hasBattery: Bool { read() != nil }

    func start() {
        guard runLoopSource == nil else { return }
        status = Self.read()
        let context = Unmanaged.passUnretained(self).toOpaque()
        guard let source = IOPSNotificationCreateRunLoopSource({ context in
            guard let context else { return }
            let monitor = Unmanaged<BatteryMonitor>.fromOpaque(context).takeUnretainedValue()
            MainActor.assumeIsolated { monitor.refresh() }
        }, context)?.takeRetainedValue() else { return }
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .defaultMode)
        runLoopSource = source
        onChange?(status)
    }

    func stop() {
        if let runLoopSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .defaultMode) }
        runLoopSource = nil
    }

    /// Re-reads now (IOPowerSources notifies on charge / state changes; watts drift in between).
    func refresh() {
        let new = Self.read()
        guard new != status else { return }
        status = new
        onChange?(new)
    }

    /// The pill to flash for a change, if any: plugged in, unplugged, fully charged, or a low threshold crossed.
    nonisolated static func toast(from old: BatteryStatus?, to new: BatteryStatus?) -> LiveToast.Kind? {
        guard let old, let new else { return nil }
        if !old.isPluggedIn, new.isPluggedIn {
            return new.percent >= 100 ? .charged : .charging(percent: new.percent)
        }
        if old.isPluggedIn, !new.isPluggedIn {
            return .onBattery(percent: new.percent, minutesLeft: new.minutesToEmpty)
        }
        if !new.isPluggedIn, lowThresholds.contains(where: { old.percent > $0 && new.percent <= $0 }) {
            return .lowBattery(percent: new.percent)
        }
        if new.isPluggedIn, old.percent < 100, new.percent >= 100 {
            return .charged
        }
        return nil
    }

    // MARK: Reading

    nonisolated static func read() -> BatteryStatus? {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else { return nil }
        for source in sources {
            guard let description = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any],
                  description[kIOPSTypeKey] as? String == kIOPSInternalBatteryType else { continue }
            let current = description[kIOPSCurrentCapacityKey] as? Int ?? 0
            let maximum = max(description[kIOPSMaxCapacityKey] as? Int ?? 100, 1)
            let positive: (String) -> Int? = { key in
                (description[key] as? Int).flatMap { $0 > 0 ? $0 : nil }
            }
            var status = BatteryStatus(
                percent: min(100, max(0, Int((Double(current) / Double(maximum) * 100).rounded()))),
                isPluggedIn: description[kIOPSPowerSourceStateKey] as? String == kIOPSACPowerValue,
                isCharging: description[kIOPSIsChargingKey] as? Bool ?? false,
                isCharged: description[kIOPSIsChargedKey] as? Bool ?? false,
                minutesToEmpty: positive(kIOPSTimeToEmptyKey),
                minutesToFull: positive(kIOPSTimeToFullChargeKey)
            )
            if status.isPluggedIn,
               let adapter = IOPSCopyExternalPowerAdapterDetails()?.takeRetainedValue() as? [String: Any] {
                status.adapterWatts = (adapter[kIOPSPowerAdapterWattsKey] as? Int).flatMap { $0 > 0 ? $0 : nil }
            }
            addSmartBatteryDetails(to: &status)
            return status
        }
        return nil
    }

    /// Voltage × current, cycle count and health from the AppleSmartBattery driver.
    nonisolated private static func addSmartBatteryDetails(to status: inout BatteryStatus) {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        guard service != 0 else { return }
        defer { IOObjectRelease(service) }
        var unmanaged: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(service, &unmanaged, kCFAllocatorDefault, 0) == KERN_SUCCESS,
              let properties = unmanaged?.takeRetainedValue() as? [String: Any] else { return }
        // Amperage is signed but can be stored as an unsigned 64-bit value; int64Value restores the sign.
        if let millivolts = (properties["Voltage"] as? NSNumber)?.int64Value,
           let milliamps = ((properties["InstantAmperage"] ?? properties["Amperage"]) as? NSNumber)?.int64Value,
           millivolts > 0 {
            status.batteryWatts = Double(millivolts) * Double(milliamps) / 1_000_000
        }
        status.cycleCount = (properties["CycleCount"] as? NSNumber)?.intValue
        if let raw = (properties["AppleRawMaxCapacity"] as? NSNumber)?.doubleValue,
           let design = (properties["DesignCapacity"] as? NSNumber)?.doubleValue, design > 0 {
            status.healthPercent = min(100, Int((raw / design * 100).rounded()))
        }
    }
}
