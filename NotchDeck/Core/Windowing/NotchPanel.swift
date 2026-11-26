import AppKit
import SwiftUI

/// Borderless, non-activating panel that floats over the menu bar at the notch.
///
/// It never steals focus from the frontmost app. Key status is opt-in via
/// `allowsKeyFocus` (used later by the AI Chat / To-Do text fields).
final class NotchPanel: NSPanel {
    /// Level while collapsed / peeking: just above the menu bar and status items.
    static let idleLevel = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)
    /// Level while expanded: above the menu bar, status items and their menus, but *below* the
    /// system drag-image layer (500). At `.screenSaver` (1000) the notch covered the dragged file's
    /// image and drops onto it were unreliable. `.fullScreenAuxiliary` keeps it over fullscreen apps.
    static let activeLevel = NSWindow.Level(rawValue: NSWindow.Level.popUpMenu.rawValue + 1)

    /// When true the panel may become key so embedded text fields can receive typing.
    var allowsKeyFocus = false
    var onEscape: (() -> Void)?

    init(contentRect: NSRect) {
        super.init(
            contentRect: contentRect,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        isFloatingPanel = true
        level = Self.idleLevel
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        isOpaque = false
        backgroundColor = .clear
        // The drop shadow is drawn in SwiftUI: a window-server shadow is computed from a
        // static alpha snapshot and would lag behind the animated silhouette.
        hasShadow = false
        isMovable = false
        isMovableByWindowBackground = false
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        becomesKeyOnlyIfNeeded = true
        animationBehavior = .none
        ignoresMouseEvents = true
    }

    override var canBecomeKey: Bool { allowsKeyFocus }
    override var canBecomeMain: Bool { false }

    /// Borderless windows are normally pushed below the menu bar; the notch lives inside it.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        frameRect
    }

    override func cancelOperation(_ sender: Any?) {
        onEscape?()
    }
}

/// Hosting view that (a) accepts first-mouse so a click works without activating the
/// app, and (b) reports pointer movement even while the panel is not key.
final class NotchHostingView<Content: View>: NSHostingView<Content> {
    var onPointerActivity: (() -> Void)?
    private var pointerTrackingArea: NSTrackingArea?

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let pointerTrackingArea { removeTrackingArea(pointerTrackingArea) }
        let area = NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        pointerTrackingArea = area
    }

    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        onPointerActivity?()
    }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        onPointerActivity?()
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        onPointerActivity?()
    }
}

/// Receives drags at the AppKit level for the File Tray.
protocol NotchDropDelegate: AnyObject {
    func notchDragUpdated(_ info: NSDraggingInfo) -> NSDragOperation
    func notchDragExited()
    func notchPerformDrop(_ info: NSDraggingInfo) -> Bool
}

/// The panel's content view: hosts the SwiftUI notch and is the native drag destination.
///
/// Drops are handled here instead of with SwiftUI's `onDrop`: reading the drag pasteboard
/// directly is the most reliable path for Finder, browsers and Slack, and keeps the drop target
/// independent of whatever SwiftUI view happens to be under the pointer.
final class NotchContainerView: NSView {
    weak var dropDelegate: NotchDropDelegate?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        registerForDraggedTypes(FileTrayStore.pasteboardTypes)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        dropDelegate?.notchDragUpdated(sender) ?? []
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        dropDelegate?.notchDragUpdated(sender) ?? []
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        dropDelegate?.notchDragExited()
    }

    override func draggingEnded(_ sender: NSDraggingInfo) {
        dropDelegate?.notchDragExited()
    }

    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool { true }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        dropDelegate?.notchPerformDrop(sender) ?? false
    }
}

/// Detects drags from any app by polling the mouse button and the drag pasteboard.
///
/// Global event monitors aren't guaranteed to see events while another app runs its drag loop,
/// so this doesn't rely on them. It only touches the pasteboard while the button is held.
final class DragSessionMonitor {
    var onDragMoved: (CGPoint) -> Void = { _ in }
    var onDragEnded: () -> Void = {}

    private var timer: Timer?
    private var wasPressed = false
    private var baselineChangeCount = 0
    private var isDragging = false

    func start() {
        let timer = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        // .common so it also fires while NotchDeck itself is tracking a drag (dragging a tray item out).
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func tick() {
        let pressed = NSEvent.pressedMouseButtons & 1 == 1
        defer { wasPressed = pressed }

        if pressed {
            let pasteboard = NSPasteboard(name: .drag)
            if !wasPressed {
                baselineChangeCount = pasteboard.changeCount
            } else if !isDragging, pasteboard.changeCount != baselineChangeCount, FileTrayStore.canAccept(pasteboard) {
                isDragging = true
            }
            if isDragging { onDragMoved(NSEvent.mouseLocation) }
        } else if wasPressed, isDragging {
            isDragging = false
            onDragEnded()
        }
    }
}
