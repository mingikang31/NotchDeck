import Observation
import ServiceManagement

/// Launch at login via `SMAppService.mainApp`. The system owns the state, so it is read back
/// from the service rather than stored in preferences.
@Observable
final class LaunchAtLoginService {
    private(set) var isEnabled = false
    /// The user must approve NotchDeck in System Settings → General → Login Items.
    private(set) var requiresApproval = false
    private(set) var lastError: String?

    init() {
        refresh()
    }

    func refresh() {
        let status = SMAppService.mainApp.status
        isEnabled = status == .enabled
        requiresApproval = status == .requiresApproval
    }

    func setEnabled(_ enabled: Bool) {
        lastError = nil
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            lastError = error.localizedDescription
        }
        refresh()
    }

    func openLoginItemsSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}
