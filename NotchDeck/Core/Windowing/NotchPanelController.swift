import AppKit
import OSLog
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
    private let chat: ChatStore
    private let agentHooks: AgentHookStore
    private var dwellTask: Task<Void, Never>?
    private var shrinkTask: Task<Void, Never>?
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
        self.chat = services.chat
        self.agentHooks = services.agentHooks

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

        model.onTap = { [weak self] in self?.expandFromPill() }
        model.onRequestCollapse = { [weak self] in self?.transition(to: .collapsed) }
        panel.onEscape = { [weak self] in self?.handleEscape() }
        hostingView.onPointerActivity = { [weak self] in
            self?.handlePointerMoved(to: NSEvent.mouseLocation)
        }

        container.dropDelegate = self
        panel.setFrame(geometry.panelFrame, display: false)
        panel.orderFrontRegardless()

        // Switching to / from the AI Chat tab changes the expanded height.
        observeContinuously({ [weak self] in
            guard let self else { return "" }
            return "\(String(describing: self.model.selectedModule))|\(self.settings.enabledModules.map(\.rawValue))|\(self.license.isUnlocked)|\(self.agentHooks.pending.isEmpty)|\(self.model.fittedBodyHeights)"
        }) { [weak self] _ in
            self?.syncPanelFrame()
        }
    }

    var isExpanded: Bool { model.state == .expanded }

    /// Width of the live-activity wings currently beside the cutout (0 when idle).
    private var wing: CGFloat { liveActivity.wingWidth }

    /// The module the expanded notch is showing (same resolution the view uses).
    private var activeModule: NotchModule? {
        ExpandedShellView.resolvedSelection(model.selectedModule, enabled: license.isUnlocked ? settings.enabledModules : [])
    }

    /// AI Chat (and a showing approval card) get the tall layout; everything else the standard one.
    private var layout: ExpandedLayout {
        .forModule(
            activeModule,
            hasPendingApproval: !agentHooks.pending.isEmpty,
            fittedHeight: activeModule.flatMap { model.fittedBodyHeights[$0] }
        )
    }

    private var expandedZone: CGRect { model.geometry.interactionZone(for: .expanded, layout: layout) }

    // MARK: Screen updates

    func update(screen: NSScreen) {
        let geometry = screen.notchGeometry(preset: settings.sizePreset)
        model.displayName = screen.localizedName
        model.refreshRate = screen.maximumFramesPerSecond
        guard geometry != model.geometry else { return }
        model.geometry = geometry
        panel.setFrame(geometry.panelFrame(for: model.state == .expanded ? layout : .standard), display: true)
    }

    /// Sizes the window for the current layout. Growing happens immediately (content is top-anchored,
    /// so nothing moves); shrinking waits for the collapse / tab-switch animation to finish.
    /// Keeping the window no taller than needed avoids an invisible strip that would eat clicks.
    private func syncPanelFrame() {
        let desired = model.geometry.panelFrame(for: model.state == .expanded ? layout : .standard)
        if desired.height >= panel.frame.height {
            shrinkTask?.cancel()
            shrinkTask = nil
            if desired != panel.frame { panel.setFrame(desired, display: true) }
            return
        }
        guard shrinkTask == nil else { return }
        shrinkTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled, let self else { return }
            self.shrinkTask = nil
            let target = self.model.geometry.panelFrame(for: self.model.state == .expanded ? self.layout : .standard)
            if target.height < self.panel.frame.height { self.panel.setFrame(target, display: true) }
        }
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
            if expandedZone.contains(point) {
                cancelPendingCollapse()
            } else {
                schedulePendingCollapse()
            }
        }
    }

    func handleMouseDown(at point: CGPoint) {
        guard model.state == .expanded, !expandedZone.contains(point) else { return }
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

    /// Hover or click on the collapsed notch: a waiting Claude Code request takes the stage, and a
    /// showing toast (new download, AirPods, Pomodoro) opens its tab.
    private func expandFromPill() {
        if !agentHooks.pending.isEmpty, settings.enabledModules.contains(.agentHooks) {
            model.selectedModule = .agentHooks
        } else if case .toast(let toast) = liveActivity.current {
            model.selectedModule = toast.module
        }
        transition(to: .expanded)
    }

    /// A module shortcut (Camera Mirror): open on that tab, or close if it's already showing.
    func toggleModule(_ module: NotchModule) {
        if model.state == .expanded, activeModule == module {
            transition(to: .collapsed)
        } else {
            expandPinned(showing: module)
        }
    }

    /// Escape: deny a showing Claude Code request; otherwise close the notch.
    private func handleEscape() {
        if model.state == .expanded, activeModule == .agentHooks, agentHooks.current != nil {
            agentHooks.deny()
        } else {
            transition(to: .collapsed)
        }
    }

    /// Shows the approval card and gives it keyboard focus so Esc / ⌘↩ work right away.
    /// The panel is non-activating: the frontmost app stays frontmost, and focus returns to it
    /// when the notch collapses after the last answer.
    func presentApproval() {
        expandPinned(showing: .agentHooks)
        panel.allowsKeyFocus = true
        panel.makeKey()
        Logger(subsystem: "com.notchdeck.NotchDeck", category: "AgentHooks")
            .notice("Approval card shown; keyboard focus: \(self.panel.isKeyWindow ? "notch" : "elsewhere", privacy: .public)")
    }

    /// True when this panel is showing an approval card (key routing checks this).
    var isShowingApproval: Bool {
        model.state == .expanded && activeModule == .agentHooks && agentHooks.current != nil
    }

    func collapse(ifShowing module: NotchModule) {
        guard model.state == .expanded, activeModule == module else { return }
        transition(to: .collapsed)
    }

    /// The AI Chat shortcut: opens the chat, or, if the chat is already open, tucks it back
    /// into the notch.
    func toggleChat() {
        if model.state == .expanded, activeModule == .aiChat {
            transition(to: .collapsed)
        } else {
            focusChat()
        }
    }

    /// Open on AI Chat with the text field focused, without activating NotchDeck
    /// (the non-activating panel takes keyboard focus; the frontmost app stays frontmost).
    func focusChat() {
        expandPinned(showing: .aiChat)
        panel.allowsKeyFocus = true
        panel.makeKey()
        chat.requestFocus()
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
        chat.isDropTargeted = false
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
        syncPanelFrame()
    }

    private func applyWindowBehavior(for state: NotchState) {
        // Collapsed: fully click-through so menu bar items beside the notch keep working.
        panel.ignoresMouseEvents = state == .collapsed
        panel.level = state == .expanded ? NotchPanel.activeLevel : NotchPanel.idleLevel
        switch state {
        case .expanded:
            // May take keyboard focus, but only when a text field is clicked (becomesKeyOnlyIfNeeded).
            panel.allowsKeyFocus = true
        case .collapsed:
            if panel.isKeyWindow {
                // Hand keyboard focus back to the app the user was in.
                panel.orderOut(nil)
                panel.orderFrontRegardless()
            }
            panel.allowsKeyFocus = false
        case .peek:
            break
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
                self.expandFromPill()
            } else {
                self.transition(to: .collapsed)
            }
        }
    }

    private func schedulePendingCollapse() {
        // Never auto-collapse while the user is typing in the notch.
        guard collapseTask == nil, !isPinnedOpen, !panel.isKeyWindow, settings.autoCollapse == .pointerExit else { return }
        collapseTask = Task { [weak self] in
            try? await Task.sleep(for: Self.collapseGrace)
            guard !Task.isCancelled, let self else { return }
            self.collapseTask = nil
            if !self.expandedZone.contains(NSEvent.mouseLocation) {
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
        // With the chat open, drops become message attachments instead of tray items.
        if model.state == .expanded, activeModule == .aiChat {
            let inside = expandedZone.contains(panel.convertPoint(toScreen: info.draggingLocation))
            chat.isDropTargeted = inside
            return inside ? .copy : []
        }
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
        chat.isDropTargeted = false
    }

    func notchPerformDrop(_ info: NSDraggingInfo) -> Bool {
        fileTray.isDropTargeted = false
        if model.state == .expanded, activeModule == .aiChat {
            chat.isDropTargeted = false
            return chat.attach(from: info.draggingPasteboard)
        }
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
