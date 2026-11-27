import AppKit
import Foundation
import Testing
@testable import NotchDeck

/// Drives the real panel controller's hover / collapse state machine with a simulated pointer.
///
/// Regression for "sometimes the notch doesn't collapse when the pointer leaves": once the panel had
/// keyboard focus (after using a text field, or opening the chat by shortcut), pointer-exit collapse
/// was skipped until a click outside, even after switching to a tab with no text field.
///
/// The panels are kept off screen (ordered out, never made key), so running the tests never shows a
/// notch, eats a click, or takes keyboard focus from the app you're using.
@Suite(.serialized)
struct CollapseBehaviorTests {
    private final class Harness {
        let defaultsName = "NotchDeckCollapse.\(UUID().uuidString)"
        let container: DependencyContainer
        let controller: NotchPanelController
        var pointer: CGPoint = .zero

        init() throws {
            let defaults = UserDefaults(suiteName: defaultsName)!
            container = DependencyContainer(defaults: defaults, secureStore: InMemorySecureStore())
            let screen = try #require(NSScreen.main)
            controller = NotchPanelController(screen: screen, displayID: try #require(screen.displayID), services: container.services)
            controller.panel.orderOut(nil)
            controller.panel.alphaValue = 0
            pointer = inside
            controller.pointerLocation = { [unowned self] in self.pointer }
        }

        var inside: CGPoint {
            let shape = controller.model.geometry.shapeRect(for: .expanded)
            return CGPoint(x: shape.midX, y: shape.midY)
        }

        var outside: CGPoint {
            let screen = controller.model.geometry.screenFrame
            return CGPoint(x: screen.midX, y: screen.minY + 40)
        }

        func move(to point: CGPoint) {
            pointer = point
            controller.handlePointerMoved(to: point)
        }

        /// A text field in the notch with focus and this text in it.
        func focusTextField(containing text: String) throws -> NSTextView {
            let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 100, height: 20))
            controller.panel.contentView?.addSubview(field)
            controller.panel.makeFirstResponder(field)
            let editor = try #require(controller.panel.firstResponder as? NSTextView)
            editor.string = text
            return editor
        }

        /// Waits for the collapse (hover close delay, 200 ms by default; slower when the parallel test run keeps the main thread busy).
        func expectCollapses(sourceLocation: SourceLocation = #_sourceLocation) async throws {
            for _ in 0..<60 where controller.model.state != .collapsed {
                try await Task.sleep(for: .milliseconds(50))
            }
            #expect(controller.model.state == .collapsed, sourceLocation: sourceLocation)
        }

        /// Gives a (wrong) collapse ample time to happen, then checks the notch is still open.
        func expectStaysOpen(sourceLocation: SourceLocation = #_sourceLocation) async throws {
            try await Task.sleep(for: .milliseconds(1200))
            #expect(controller.model.state == .expanded, sourceLocation: sourceLocation)
        }

        func tearDown() {
            controller.close()
            UserDefaults().removePersistentDomain(forName: defaultsName)
        }
    }

    @Test func hoverOpenedNotchCollapsesWhenPointerLeaves() async throws {
        let h = try Harness()
        defer { h.tearDown() }
        h.controller.model.onTap()
        #expect(h.controller.model.state == .expanded)
        h.move(to: h.outside)
        try await h.expectCollapses()
    }

    @Test func hoverCloseDelayIsHonored() async throws {
        let h = try Harness()
        defer { h.tearDown() }
        h.container.settings.hoverCloseDelayMilliseconds = 500
        h.controller.model.onTap()
        h.move(to: h.outside)
        try await Task.sleep(for: .milliseconds(250))
        #expect(h.controller.model.state == .expanded)   // still within the delay
        try await h.expectCollapses()                     // closes once it has passed
    }

    @Test func comingBackWithinTheCloseDelayKeepsItOpen() async throws {
        let h = try Harness()
        defer { h.tearDown() }
        h.container.settings.hoverCloseDelayMilliseconds = 500
        h.controller.model.onTap()
        h.move(to: h.outside)
        try await Task.sleep(for: .milliseconds(150))
        h.move(to: h.inside)
        try await h.expectStaysOpen()
    }

    @Test func zeroCloseDelayClosesRightAway() async throws {
        let h = try Harness()
        defer { h.tearDown() }
        h.container.settings.hoverCloseDelayMilliseconds = 0
        h.controller.model.onTap()
        h.move(to: h.outside)
        try await h.expectCollapses()
    }

    @Test func returningInsideCancelsTheCollapse() async throws {
        let h = try Harness()
        defer { h.tearDown() }
        h.controller.model.onTap()
        h.move(to: h.outside)
        h.move(to: h.inside)
        try await h.expectStaysOpen()
    }

    /// The old bug: a text field that had been used (now empty) kept the notch open on pointer exit.
    @Test func usedButEmptyTextFieldDoesNotBlockCollapse() async throws {
        let h = try Harness()
        defer { h.tearDown() }
        h.controller.model.onTap()
        _ = try h.focusTextField(containing: "")
        h.move(to: h.outside)
        try await h.expectCollapses()
    }

    @Test func unsentDraftKeepsItOpenUntilEmptied() async throws {
        let h = try Harness()
        defer { h.tearDown() }
        h.controller.model.onTap()
        let editor = try h.focusTextField(containing: "half-written question")
        #expect(h.controller.isEditingDraft)

        h.move(to: h.outside)
        try await h.expectStaysOpen()

        editor.string = "   "       // sent / cleared (whitespace only counts as empty)
        h.move(to: h.outside.applying(.init(translationX: 5, y: 0)))
        try await h.expectCollapses()
    }

    @Test func chatShortcutStaysOpenUntilAnotherTabIsClicked() async throws {
        let h = try Harness()
        defer { h.tearDown() }
        h.controller.expandPinned(showing: .aiChat)   // what the Open AI Chat shortcut does (minus focus)
        #expect(h.controller.isPinnedOpen)
        h.move(to: h.outside)
        try await h.expectStaysOpen()                 // shortcut-opened chat stays put

        h.move(to: h.inside)
        h.controller.model.selectedModule = .media
        h.controller.model.onUserSelectedModule(.media) // user clicks the Media tab
        #expect(!h.controller.isPinnedOpen)
        h.move(to: h.outside)
        try await h.expectCollapses()                 // now behaves like a hover-opened notch
    }

    @Test func tabClickWithPointerAlreadyOutsideStillCollapses() async throws {
        let h = try Harness()
        defer { h.tearDown() }
        h.controller.expandPinned(showing: .aiChat)
        h.pointer = h.outside                         // clicked, then left before any further move event
        h.controller.model.onUserSelectedModule(.calendar)
        try await h.expectCollapses()
    }

    @Test func clickingTheSameTabKeepsThePin() async throws {
        let h = try Harness()
        defer { h.tearDown() }
        h.controller.expandPinned(showing: .aiChat)
        h.controller.model.onUserSelectedModule(.aiChat)
        #expect(h.controller.isPinnedOpen)
    }

    @Test func notchToggleShortcutStaysPinnedAcrossTabs() async throws {
        let h = try Harness()
        defer { h.tearDown() }
        h.controller.toggle()      // ⌃⌥N
        h.controller.model.onUserSelectedModule(.calendar)
        #expect(h.controller.isPinnedOpen)
        h.move(to: h.outside)
        try await h.expectStaysOpen()
        h.controller.toggle()
        #expect(h.controller.model.state == .collapsed)
    }

    @Test func clickOutsideModeIgnoresPointerExit() async throws {
        let h = try Harness()
        defer { h.tearDown() }
        h.container.settings.autoCollapse = .clickOutside
        h.controller.model.onTap()
        h.move(to: h.outside)
        try await h.expectStaysOpen()
        h.controller.handleMouseDown(at: h.outside)
        #expect(h.controller.model.state == .collapsed)
    }
}

struct ShortcutHintTests {
    @Test func describesTheRecordedShortcut() {
        let description = ShortcutAction.openAIChat.currentShortcutDescription
        #expect(description == nil || description?.isEmpty == false)
        #expect(ShortcutAction.didChangeNotification.rawValue == "KeyboardShortcuts_shortcutByNameDidChange")
    }
}
