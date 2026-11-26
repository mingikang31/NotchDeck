import AppKit
import OSLog

/// Multi-screen lifecycle: one `NotchPanelController` per targeted display, rebuilt on display
/// reconfiguration and on relevant settings changes, fed by global + local mouse monitors.
final class NotchWindowController {
    private let services: AppServices
    private var controllers: [CGDirectDisplayID: NotchPanelController] = [:]
    private var eventMonitors: [Any] = []
    private var screenObserver: NSObjectProtocol?
    private let dragMonitor = DragSessionMonitor()
    private let logger = Logger(subsystem: "com.notchdeck.NotchDeck", category: "Windowing")

    private var settings: SettingsStore { services.settings }

    init(services: AppServices) {
        self.services = services
    }

    func start() {
        rebuildPanels()
        installEventMonitors()
        dragMonitor.onDragMoved = { [weak self] point in
            guard let self, self.settings.enabledModules.contains(.fileTray), self.services.licenseManager.isUnlocked else { return }
            self.controllers.values.forEach { $0.handleDragHover(at: point) }
        }
        dragMonitor.onDragEnded = { [weak self] in
            self?.controllers.values.forEach { $0.endDragSession() }
        }
        dragMonitor.start()
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.rebuildPanels() }
        }
        observeContinuously({ [weak self] in
            "\(self?.settings.displayPolicy.rawValue ?? "")|\(self?.settings.sizePreset.rawValue ?? "")"
        }) { [weak self] _ in
            self?.rebuildPanels()
        }
    }

    func stop() {
        dragMonitor.stop()
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
                controllers[id] = NotchPanelController(screen: screen, displayID: id, services: services)
                logGeometry(for: screen)
            }
        }
    }

    private func targetScreens() -> [NSScreen] {
        let screens = NSScreen.screens
        switch settings.displayPolicy {
        case .allDisplays:
            return screens
        case .followActiveScreen:
            let mouse = NSEvent.mouseLocation
            if let active = screens.first(where: { $0.frame.contains(mouse) }) ?? NSScreen.main { return [active] }
            return screens.first.map { [$0] } ?? []
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

    func expandPinned(showing module: NotchModule? = nil) {
        activeController()?.expandPinned(showing: module)
    }

    func focusChat() {
        activeController()?.focusChat()
    }

    /// Shortcut behavior: open the chat, or close it if it's already showing.
    func toggleChat() {
        if let open = controllers.values.first(where: \.isExpanded) {
            open.toggleChat()
        } else {
            activeController()?.toggleChat()
        }
    }

    /// A Claude Code approval arrived: open the notch on the card (screen under the pointer).
    func showAgentApproval() {
        if let open = controllers.values.first(where: \.isExpanded) {
            open.presentApproval()
        } else {
            activeController()?.presentApproval()
        }
    }

    func collapse(ifShowing module: NotchModule) {
        controllers.values.forEach { $0.collapse(ifShowing: module) }
    }

    func collapseAll() {
        controllers.values.forEach { $0.transition(to: .collapsed) }
    }

    var isAnyExpanded: Bool { controllers.values.contains(where: \.isExpanded) }

    private func activeController() -> NotchPanelController? {
        if settings.displayPolicy == .followActiveScreen { rebuildPanels() }
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

        // Approval card keys: Esc denies, ⌘↩ approves, ⌘⇧↩ always allows. Handled here rather than
        // through SwiftUI shortcuts / cancelOperation, which don't reliably reach a non-activating panel.
        if let keys = NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: { [weak self] event in
            guard let self, let panel = event.window as? NotchPanel,
                  let controller = self.controllers.values.first(where: { $0.panel === panel }),
                  controller.isShowingApproval,
                  let action = AgentHookStore.keyAction(keyCode: event.keyCode, modifiers: event.modifierFlags) else {
                return event
            }
            self.services.agentHooks.perform(action)
            return nil
        }) {
            eventMonitors.append(keys)
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
        followPointerIfNeeded(point)
        for controller in controllers.values {
            switch type {
            case .leftMouseDown, .rightMouseDown:
                controller.handleMouseDown(at: point)
            default:
                controller.handlePointerMoved(to: point)
            }
        }
    }

    /// In Follow Active Screen mode, move the notch when the pointer crosses onto another display
    /// (only while collapsed, so an open notch never jumps away mid-interaction).
    private func followPointerIfNeeded(_ point: CGPoint) {
        guard settings.displayPolicy == .followActiveScreen, !isAnyExpanded,
              let current = controllers.values.first,
              !current.model.geometry.screenFrame.contains(point),
              NSScreen.screens.contains(where: { $0.frame.contains(point) }) else { return }
        rebuildPanels()
    }
}
