import AppKit
import SwiftUI

/// Owns one `NotchPanel` for one display and runs its hover / click state machine.
///
///     collapsed ──hover──▶ peek ──dwell (150ms)──▶ expanded
///         ▲                 │                        │
///         └────leave────────┘◀──leave / click-out / Esc──┘
///     click on collapsed or peek ──────────────────▶ expanded
final class NotchPanelController {
    let displayID: CGDirectDisplayID
    let model: NotchViewModel
    let panel: NotchPanel

    private let settings: SettingsStore
    private let liveActivity: LiveActivityCoordinator
    private let fileTray: FileTrayStore
    private let license: LicenseManager
    private var dwellTask: Task<Void, Never>?
    private var collapseTask: Task<Void, Never>?
    /// Set when opened explicitly (menu / shortcut): pointer exit then won't auto-collapse.
    private var isPinnedOpen = false

    private static let collapseGrace: Duration = .milliseconds(220)

    init(screen: NSScreen, displayID: CGDirectDisplayID, services: AppServices) {
        self.displayID = displayID
        self.settings = services.settings
        self.liveActivity = services.liveActivity
        self.fileTray = services.fileTray
        self.license = services.licenseManager

        let geometry = screen.notchGeometry(preset: settings.sizePreset)
        model = NotchViewModel(
            geometry: geometry,
            displayName: screen.localizedName,
            refreshRate: screen.maximumFramesPerSecond
        )
        panel = NotchPanel(contentRect: geometry.panelFrame)

        let hostingView = NotchHostingView(
            rootView: NotchPanelContent(model: model, services: services)
        )
        // Never let SwiftUI resize the window to its ideal size; the frame is ours.
        hostingView.sizingOptions = []
        hostingView.frame = NSRect(origin: .zero, size: geometry.panelFrame.size)
        hostingView.autoresizingMask = [.width, .height]
        let container = NotchContainerView(frame: NSRect(origin: .zero, size: geometry.panelFrame.size))
        container.addSubview(hostingView)
        panel.contentView = container

        model.onTap = { [weak self] in self?.transition(to: .expanded) }
        model.onRequestCollapse = { [weak self] in self?.transition(to: .collapsed) }
        panel.onEscape = { [weak self] in self?.transition(to: .collapsed) }
        hostingView.onPointerActivity = { [weak self] in
            self?.handlePointerMoved(to: NSEvent.mouseLocation)
        }

        container.dropDelegate = self
        panel.setFrame(geometry.panelFrame, display: false)
        panel.orderFrontRegardless()
    }

    var isExpanded: Bool { model.state == .expanded }

    /// Width of the live-activity wings currently beside the cutout (0 when idle).
    private var wing: CGFloat { liveActivity.wingWidth }

    // MARK: Screen updates

    func update(screen: NSScreen) {
        let geometry = screen.notchGeometry(preset: settings.sizePreset)
        model.displayName = screen.localizedName
        model.refreshRate = screen.maximumFramesPerSecond
        guard geometry != model.geometry else { return }
        model.geometry = geometry
        panel.setFrame(geometry.panelFrame, display: true)
    }

    func close() {
        dwellTask?.cancel()
        collapseTask?.cancel()
        panel.orderOut(nil)
        panel.close()
    }

    // MARK: Pointer input (global coordinates)

    func handlePointerMoved(to point: CGPoint) {
        let geometry = model.geometry
        switch model.state {
        case .collapsed:
            if geometry.interactionZone(for: .collapsed, wing: wing).contains(point) {
                beginHoverIntent()
            }
        case .peek:
            if !geometry.interactionZone(for: .peek, wing: wing).contains(point) {
                transition(to: .collapsed)
            }
        case .expanded:
            if geometry.interactionZone(for: .expanded).contains(point) {
                cancelPendingCollapse()
            } else {
                schedulePendingCollapse()
            }
        }
    }

    func handleMouseDown(at point: CGPoint) {
        guard model.state == .expanded,
              !model.geometry.interactionZone(for: .expanded).contains(point) else { return }
        transition(to: .collapsed)
    }

    // MARK: Explicit control

    func toggle() {
        if model.state == .expanded {
            transition(to: .collapsed)
        } else {
            transition(to: .expanded)
            isPinnedOpen = true
        }
    }

    func expandPinned(showing module: NotchModule? = nil) {
        if let module { model.selectedModule = module }
        transition(to: .expanded)
        isPinnedOpen = true
    }

    /// A file drag is in progress: open straight into the File Tray when it reaches the notch,
    /// so the file can be dropped in one gesture.
    func handleDragHover(at point: CGPoint) {
        // While a file drag is in flight the panel must be able to receive it even when collapsed
        // (normally collapsed = click-through). Restored on mouse-up / collapse.
        if panel.ignoresMouseEvents { panel.ignoresMouseEvents = false }
        guard model.state != .expanded,
              model.geometry.interactionZone(for: .peek, wing: wing).contains(point) else { return }
        openForDrop()
    }

    /// The drag session ended (mouse-up anywhere).
    func endDragSession() {
        fileTray.isDropTargeted = false
        if model.state == .collapsed { panel.ignoresMouseEvents = true }
    }

    private var acceptsDrops: Bool {
        license.isUnlocked && settings.enabledModules.contains(.fileTray)
    }

    private func openForDrop() {
        model.selectedModule = .fileTray
        if model.state != .expanded { transition(to: .expanded) }
    }

    // MARK: State machine

    func transition(to newState: NotchState) {
        dwellTask?.cancel()
        dwellTask = nil
        cancelPendingCollapse()
        if newState != .expanded { isPinnedOpen = false }
        guard newState != model.state else { return }

        withAnimation(NotchMotion.animation(to: newState)) {
            model.state = newState
        }
        applyWindowBehavior(for: newState)
    }

    private func applyWindowBehavior(for state: NotchState) {
        // Collapsed: fully click-through so menu bar items beside the notch keep working.
        panel.ignoresMouseEvents = state == .collapsed
        panel.level = state == .expanded ? NotchPanel.activeLevel : NotchPanel.idleLevel
        if state == .collapsed {
            panel.allowsKeyFocus = false
        }
    }

    private func beginHoverIntent() {
        let delay = settings.hoverDelayMilliseconds
        guard delay > 0 else {
            transition(to: .expanded)
            return
        }
        transition(to: .peek)
        dwellTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(delay))
            guard !Task.isCancelled, let self, self.model.state == .peek else { return }
            if self.model.geometry.interactionZone(for: .peek, wing: self.wing).contains(NSEvent.mouseLocation) {
                self.transition(to: .expanded)
            } else {
                self.transition(to: .collapsed)
            }
        }
    }

    private func schedulePendingCollapse() {
        guard collapseTask == nil, !isPinnedOpen, settings.autoCollapse == .pointerExit else { return }
        collapseTask = Task { [weak self] in
            try? await Task.sleep(for: Self.collapseGrace)
            guard !Task.isCancelled, let self else { return }
            self.collapseTask = nil
            if !self.model.geometry.interactionZone(for: .expanded).contains(NSEvent.mouseLocation) {
                self.transition(to: .collapsed)
            }
        }
    }

    private func cancelPendingCollapse() {
        collapseTask?.cancel()
        collapseTask = nil
    }
}

// MARK: - Drop destination

extension NotchPanelController: NotchDropDelegate {
    func notchDragUpdated(_ info: NSDraggingInfo) -> NSDragOperation {
        guard acceptsDrops, FileTrayStore.canAccept(info.draggingPasteboard) else {
            fileTray.isDropTargeted = false
            return []
        }
        let point = panel.convertPoint(toScreen: info.draggingLocation)
        let zone = model.state == .expanded
            ? model.geometry.interactionZone(for: .expanded)
            : model.geometry.interactionZone(for: .peek, wing: wing)
        guard zone.contains(point) else {
            fileTray.isDropTargeted = false
            return []
        }
        openForDrop()
        fileTray.isDropTargeted = true
        return .copy
    }

    func notchDragExited() {
        fileTray.isDropTargeted = false
    }

    func notchPerformDrop(_ info: NSDraggingInfo) -> Bool {
        fileTray.isDropTargeted = false
        guard acceptsDrops else { return false }
        model.selectedModule = .fileTray
        return fileTray.handleDrop(pasteboard: info.draggingPasteboard)
    }
}

/// Root content for a panel's hosting view, with shared stores injected.
struct NotchPanelContent: View {
    let model: NotchViewModel
    let services: AppServices

    var body: some View {
        NotchRootView(model: model)
            .appServices(services)
    }
}
