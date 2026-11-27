import Foundation
import IOBluetooth
import IOKit

/// Carries an IOBluetoothDevice from IOBluetooth's background queue to the main thread (the object is
/// only touched there).
nonisolated private final class DeviceBox: @unchecked Sendable {
    let device: IOBluetoothDevice
    init(_ device: IOBluetoothDevice) { self.device = device }
}

/// A connected Bluetooth device as the notch shows it.
nonisolated struct BluetoothDeviceInfo: Identifiable, Equatable, Sendable {
    struct Battery: Equatable, Sendable {
        /// "L", "R", "Case", or "" for a single battery.
        var label: String
        var percent: Int
    }

    var id: String
    var name: String
    var symbol: String
    var batteries: [Battery]

    /// The lowest earbud / device level, for the compact pill.
    var headlineBattery: Int? {
        let buds = batteries.filter { $0.label != "Case" }
        return (buds.isEmpty ? batteries : buds).map(\.percent).min()
    }

    /// SF Symbol for a device, from its name and Bluetooth class.
    static func symbol(name: String, major: UInt32, minor: UInt32) -> String {
        let lower = name.lowercased()
        if lower.contains("airpods max") { return "airpodsmax" }
        if lower.contains("airpods pro") { return "airpodspro" }
        if lower.contains("airpods") { return "airpods" }
        if lower.contains("beats") { return "beats.headphones" }
        if lower.contains("trackpad") { return "hand.point.up.left" }
        if lower.contains("mouse") { return "magicmouse" }
        if lower.contains("keyboard") { return "keyboard" }
        if lower.contains("controller") || lower.contains("dualsense") || lower.contains("xbox") { return "gamecontroller" }
        switch major {
        case 0x04: return "headphones"                               // audio / video
        case 0x05:                                                    // peripheral
            if minor & 0x10 != 0 { return "keyboard" }
            if minor & 0x20 != 0 { return "magicmouse" }
            return "gamecontroller"
        case 0x02: return "iphone"                                    // phone
        default: return "dot.radiowaves.left.and.right"
        }
    }
}

/// Connection notifications from IOBluetooth, with battery levels where the device reports them
/// (AirPods / Beats via IOBluetooth, Magic Keyboard / Mouse / Trackpad via their HID service).
///
/// The first use of Bluetooth asks for permission (Privacy & Security → Bluetooth).
final class BluetoothMonitor: NSObject {
    /// Fired after a device connects (once its battery levels have had a moment to arrive).
    var onConnect: ((BluetoothDeviceInfo) -> Void)?
    var onDevicesChanged: (([BluetoothDeviceInfo]) -> Void)?

    private var connectNotification: IOBluetoothUserNotification?
    private var disconnectNotifications: [String: IOBluetoothUserNotification] = [:]
    private var connected: [String: IOBluetoothDevice] = [:]
    /// Devices already connected at start are listed but don't toast.
    private var quietUntil = Date.distantPast
    private var refreshTask: Task<Void, Never>?

    func start() {
        guard connectNotification == nil else { return }
        quietUntil = Date().addingTimeInterval(3)
        connectNotification = IOBluetoothDevice.register(
            forConnectNotifications: self, selector: #selector(deviceConnected(_:fromDevice:))
        )
        for device in (IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice] ?? []) where device.isConnected() {
            track(device)
        }
        publish()
        // Battery levels change slowly; re-read every minute while running.
        refreshTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(60))
                self?.publish()
            }
        }
    }

    func stop() {
        connectNotification?.unregister()
        connectNotification = nil
        disconnectNotifications.values.forEach { $0.unregister() }
        disconnectNotifications.removeAll()
        connected.removeAll()
        refreshTask?.cancel()
        refreshTask = nil
        onDevicesChanged?([])
    }

    var devices: [BluetoothDeviceInfo] {
        connected.values.map(Self.info(for:)).sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    func publish() {
        onDevicesChanged?(devices)
    }

    // IOBluetooth posts these from a CoreBluetooth background queue, not the main thread. They must be
    // `nonisolated` (a main-actor method called off the main thread is a deliberate crash in Swift 6:
    // it took NotchDeck down on every launch while AirPods were connected) and hop to the main thread.

    @objc nonisolated private func deviceConnected(_ notification: IOBluetoothUserNotification, fromDevice device: IOBluetoothDevice) {
        let box = DeviceBox(device)
        Self.onMain { [weak self] in self?.handleConnected(box.device) }
    }

    @objc nonisolated private func deviceDisconnected(_ notification: IOBluetoothUserNotification, fromDevice device: IOBluetoothDevice) {
        let box = DeviceBox(device)
        Self.onMain { [weak self] in self?.handleDisconnected(box.device) }
    }

    /// Runs `work` on the main thread: right away if already there, otherwise asynchronously.
    nonisolated static func onMain(_ work: @escaping @MainActor @Sendable () -> Void) {
        if Thread.isMainThread {
            MainActor.assumeIsolated { work() }
        } else {
            DispatchQueue.main.async { MainActor.assumeIsolated { work() } }
        }
    }

    private func handleConnected(_ device: IOBluetoothDevice) {
        let isNew = connected[Self.key(device)] == nil
        track(device)
        publish()
        guard isNew, Date() >= quietUntil else { return }
        // AirPods report their levels a moment after connecting.
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(1500))
            guard let self, self.connected[Self.key(device)] != nil else { return }
            self.onConnect?(Self.info(for: device))
            self.publish()
        }
    }

    private func handleDisconnected(_ device: IOBluetoothDevice) {
        let key = Self.key(device)
        disconnectNotifications.removeValue(forKey: key)?.unregister()
        connected.removeValue(forKey: key)
        publish()
    }

    private func track(_ device: IOBluetoothDevice) {
        let key = Self.key(device)
        connected[key] = device
        if disconnectNotifications[key] == nil {
            disconnectNotifications[key] = device.register(
                forDisconnectNotification: self, selector: #selector(deviceDisconnected(_:fromDevice:))
            )
        }
    }

    private static func key(_ device: IOBluetoothDevice) -> String {
        device.addressString ?? device.name ?? "\(ObjectIdentifier(device).hashValue)"
    }

    private static func info(for device: IOBluetoothDevice) -> BluetoothDeviceInfo {
        let name = device.name ?? "Bluetooth device"
        var batteries = audioBatteries(of: device)
        if batteries.isEmpty, let level = hidBatteryLevel(address: device.addressString, name: name) {
            batteries = [.init(label: "", percent: level)]
        }
        return BluetoothDeviceInfo(
            id: key(device),
            name: name,
            symbol: BluetoothDeviceInfo.symbol(name: name, major: device.deviceClassMajor, minor: device.deviceClassMinor),
            batteries: batteries
        )
    }

    /// AirPods / Beats levels. These properties aren't in the public header, so each is checked
    /// before it's read; 0 means "not reported".
    private static func audioBatteries(of device: IOBluetoothDevice) -> [BluetoothDeviceInfo.Battery] {
        func level(_ key: String) -> Int? {
            guard device.responds(to: NSSelectorFromString(key)),
                  let value = (device.value(forKey: key) as? NSNumber)?.intValue, (1...100).contains(value) else { return nil }
            return value
        }
        let parts = [("L", "batteryPercentLeft"), ("R", "batteryPercentRight"), ("Case", "batteryPercentCase")]
            .compactMap { label, key in level(key).map { BluetoothDeviceInfo.Battery(label: label, percent: $0) } }
        if !parts.isEmpty { return parts }
        if let single = level("batteryPercentSingle") ?? level("batteryPercentCombined") {
            return [.init(label: "", percent: single)]
        }
        return []
    }

    /// Magic Keyboard / Mouse / Trackpad publish BatteryPercent on their HID event service.
    private static func hidBatteryLevel(address: String?, name: String) -> Int? {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("AppleDeviceManagementHIDEventService"), &iterator) == KERN_SUCCESS else { return nil }
        defer { IOObjectRelease(iterator) }
        let wantedAddress = address.map(normalize)
        while case let service = IOIteratorNext(iterator), service != 0 {
            defer { IOObjectRelease(service) }
            func property(_ key: String) -> Any? {
                IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
            }
            guard let percent = (property("BatteryPercent") as? NSNumber)?.intValue else { continue }
            let serviceAddress = (property("DeviceAddress") as? String).map(normalize)
            let product = property("Product") as? String
            if (wantedAddress != nil && serviceAddress == wantedAddress) || product == name {
                return percent
            }
        }
        return nil
    }

    private static func normalize(_ address: String) -> String {
        address.lowercased().replacingOccurrences(of: ":", with: "-")
    }
}
