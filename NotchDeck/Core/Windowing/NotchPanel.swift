import AppKit
import SwiftUI

/// Borderless, non-activating panel that floats over the menu bar at the notch.
///
/// It never steals focus from the frontmost app. Key status is opt-in via
/// `allowsKeyFocus` (used later by the AI Chat / To-Do text fields).
final class NotchPanel: NSPanel {
    /// Level while collapsed / peeking: just above the menu bar and status items.
    static let idleLevel = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)
    /// Level while expanded: above everything, including fullscreen-app chrome.
    static let activeLevel = NSWindow.Level.screenSaver

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
