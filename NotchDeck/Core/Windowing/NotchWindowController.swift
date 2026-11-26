import AppKit
import OSLog

/// Which displays get a notch surface. (Phase 2 adds "Follow Active Screen".)
enum DisplayPolicy: String, CaseIterable, Identifiable, Sendable {
    /// The built-in notched display, or the menu-bar display if no notch exists.
    case notchDisplay
    case allDisplays

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .notchDisplay: "Notch Display Only"
        case .allDisplays: "All Displays"
        }
    }
}

/// Multi-screen lifecycle: one `NotchPanelController` per targeted display, rebuilt on
/// display reconfiguration, fed by global + local mouse monitors.
final class NotchWindowController {
    private let settings: SettingsStore
    private let themeEngine: ThemeEngine
    private var controllers: [CGDirectDisplayID: NotchPanelController] = [:]
    private var eventMonitors: [Any] = []
    private var screenObserver: NSObjectProtocol?

    private let logger = Logger(subsystem: "com.notchdeck.NotchDeck", category: "Windowing")

    init(settings: SettingsStore, themeEngine: ThemeEngine) {
        self.settings = settings
        self.themeEngine = themeEngine
    }

    func start() {
        rebuildPanels()
        installEventMonitors()
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.rebuildPanels() }
        }
    }

    func stop() {
        eventMonitors.forEach(NSEvent.removeMonitor)
        eventMonitors.removeAll()
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
        controllers.values.forEach { $0.close() }
        controllers.removeAll()
    }

    // MARK: Panels

    func rebuildPanels() {
        let targets = targetScreens()
        let targetIDs = Set(targets.compactMap(\.displayID))

        for (id, controller) in controllers where !targetIDs.contains(id) {
            controller.close()
            controllers[id] = nil
        }

        for screen in targets {
            guard let id = screen.displayID else { continue }
            if let existing = controllers[id] {
                existing.update(screen: screen)
            } else {
                controllers[id] = NotchPanelController(
                    screen: screen,
                    displayID: id,
                    settings: settings,
                    themeEngine: themeEngine
                )
            }
            logGeometry(for: screen)
        }
    }

    private func targetScreens() -> [NSScreen] {
        let screens = NSScreen.screens
        switch settings.displayPolicy {
        case .allDisplays:
            return screens
        case .notchDisplay:
            if let notched = screens.first(where: \.hasHardwareNotch) { return [notched] }
            return screens.first.map { [$0] } ?? []
        }
    }

    private func logGeometry(for screen: NSScreen) {
        let g = screen.notchGeometry(preset: settings.sizePreset)
        let kind = g.kind == .hardwareNotch ? "hardware-notch" : "fallback-pill"
        logger.notice("""
            display=\(screen.localizedName, privacy: .public) kind=\(kind, privacy: .public) \
            cutout=\(NSStringFromRect(g.cutout), privacy: .public) \
            panel=\(NSStringFromRect(g.panelFrame), privacy: .public)
            """)
    }

    // MARK: Explicit control

    /// Toggles the panel on the screen under the pointer (or the first panel).
    func toggleExpanded() {
        activeController()?.toggle()
    }

    func expandPinned() {
        activeController()?.expandPinned()
    }

    var isAnyExpanded: Bool { controllers.values.contains(where: \.isExpanded) }

    private func activeController() -> NotchPanelController? {
        let mouse = NSEvent.mouseLocation
        if let screen = NSScreen.screens.first(where: { $0.frame.contains(mouse) }),
           let id = screen.displayID, let controller = controllers[id] {
            return controller
        }
        return targetScreens().first.flatMap { $0.displayID }.flatMap { controllers[$0] }
            ?? controllers.values.first
    }

    // MARK: Mouse monitoring

    private func installEventMonitors() {
        let mask: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged, .leftMouseDown, .rightMouseDown]

        // Global: events going to other apps (no Accessibility permission needed for mouse events).
        if let global = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { [weak self] event in
            let type = event.type
            MainActor.assumeIsolated { self?.route(type) }
        }) {
            eventMonitors.append(global)
        }

        // Local: events delivered to NotchDeck itself (e.g. over our panel or Settings).
        if let local = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { [weak self] event in
            self?.route(event.type)
            return event
        }) {
            eventMonitors.append(local)
        }
    }

    private func route(_ type: NSEvent.EventType) {
        let point = NSEvent.mouseLocation
        for controller in controllers.values {
            switch type {
            case .leftMouseDown, .rightMouseDown:
                controller.handleMouseDown(at: point)
            default:
                controller.handlePointerMoved(to: point)
            }
        }
    }
}
