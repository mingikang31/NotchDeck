import AppKit
import Foundation
import Observation

/// Battery, Bluetooth and Downloads telemetry for the Live Activities tab and the collapsed pills.
@Observable
final class LiveActivitiesStore {
    /// Which watchers should run (module enabled + each feature's toggle in Settings).
    struct Activation: Equatable, Sendable {
        var battery = false
        var bluetooth = false
        var downloads = false

        static let off = Activation()
    }

    static let maximumDownloads = 6

    private(set) var battery: BatteryStatus?
    private(set) var devices: [BluetoothDeviceInfo] = []
    private(set) var downloads: [DownloadItem] = []
    private(set) var downloadsUnreadable = false
    private(set) var activation = Activation.off

    /// Desktops have no internal battery; the battery card and pills are skipped.
    @ObservationIgnored let hasBattery = BatteryMonitor.hasBattery

    @ObservationIgnored private let toasts: NotchToastCenter
    @ObservationIgnored private let batteryMonitor = BatteryMonitor()
    @ObservationIgnored private let bluetoothMonitor = BluetoothMonitor()
    @ObservationIgnored private let downloadsWatcher = DownloadsWatcher()
    @ObservationIgnored private var visibleViews = 0
    @ObservationIgnored private var pollTask: Task<Void, Never>?

    init(toasts: NotchToastCenter) {
        self.toasts = toasts
        batteryMonitor.onChange = { [weak self] status in self?.batteryChanged(status) }
        bluetoothMonitor.onDevicesChanged = { [weak self] devices in self?.devices = devices }
        bluetoothMonitor.onConnect = { [weak self] device in
            guard self?.activation.bluetooth == true else { return }
            self?.toasts.show(LiveToast(.deviceConnected(name: device.name, symbol: device.symbol, battery: device.headlineBattery)))
        }
        downloadsWatcher.onNewFile = { [weak self] item in self?.downloadArrived(item) }
    }

    func apply(_ new: Activation) {
        let old = activation
        activation = new

        let wantsBattery = new.battery && hasBattery
        if wantsBattery != (old.battery && hasBattery) {
            if wantsBattery { batteryMonitor.start() } else { batteryMonitor.stop(); battery = nil }
        }
        if new.bluetooth != old.bluetooth {
            if new.bluetooth { bluetoothMonitor.start() } else { bluetoothMonitor.stop() }
        }
        if new.downloads != old.downloads {
            if new.downloads {
                Task {
                    let seed = await downloadsWatcher.start()
                    downloadsUnreadable = !downloadsWatcher.isReadable
                    if downloads.isEmpty { downloads = seed }
                }
            } else {
                downloadsWatcher.stop()
            }
        }
    }

    // MARK: Visibility (live watts while the tab is open)

    func viewAppeared() {
        visibleViews += 1
        pruneMissingDownloads()
        bluetoothMonitor.publish()
        guard pollTask == nil else { return }
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                self?.batteryMonitor.refresh()
                try? await Task.sleep(for: .seconds(3))
            }
        }
    }

    func viewDisappeared() {
        visibleViews = max(0, visibleViews - 1)
        guard visibleViews == 0 else { return }
        pollTask?.cancel()
        pollTask = nil
    }

    // MARK: Downloads

    func removeDownload(_ item: DownloadItem) {
        downloads.removeAll { $0.id == item.id }
    }

    func clearDownloads() {
        downloads.removeAll()
    }

    var downloadsFolder: URL { downloadsWatcher.directory }

    /// Downloads that were moved or deleted since they arrived drop off the list.
    private func pruneMissingDownloads() {
        downloads.removeAll { !FileManager.default.fileExists(atPath: $0.url.path) }
    }

    private func downloadArrived(_ item: DownloadItem) {
        downloads.removeAll { $0.id == item.id }
        downloads.insert(item, at: 0)
        if downloads.count > Self.maximumDownloads { downloads.removeLast(downloads.count - Self.maximumDownloads) }
        toasts.show(LiveToast(.download(name: item.name)))
    }

    // MARK: Battery

    private func batteryChanged(_ status: BatteryStatus?) {
        let old = battery
        battery = status
        if activation.battery, let kind = BatteryMonitor.toast(from: old, to: status) {
            toasts.show(LiveToast(kind))
        }
    }
}
