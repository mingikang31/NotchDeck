import AppKit
import SwiftUI

/// Expanded Terminal: a full terminal running your login shell, styled like the AI Chat composer.
/// Clicking the tab (or the terminal) gives it keyboard focus; it keeps focus between commands.
/// The notch stays open while it has focus (click outside or press ⌃⌥N to close), and the session
/// keeps running when the notch closes.
struct TerminalModuleView: View {
    let tokens: ThemeTokens

    @Environment(TerminalSession.self) private var session

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Label(directoryLabel, systemImage: "apple.terminal")
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(tokens.secondaryText)
                    .lineLimit(1)
                    .truncationMode(.head)
                Spacer()
                Text(session.hasFocus ? "⌘C copy · ⌘V paste · ⌘K clear · ⌘+/⌘− size" : "Click to type")
                    .font(.system(size: 9.5))
                    .foregroundStyle(tokens.secondaryText)
                NotchPillButton(title: "New Session", symbol: "arrow.clockwise", tokens: tokens) {
                    session.newSession()
                    DispatchQueue.main.async { session.focus() }
                }
                .help("End this shell (and anything running in it) and start a fresh one")
            }

            ZStack {
                TerminalHost(session: session, generation: session.generation)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                if !session.isRunning {
                    VStack(spacing: 8) {
                        Text(session.exitCode.map { "Shell exited (\($0))" } ?? "Shell not running")
                            .font(.system(size: 12.5, weight: .semibold))
                        NotchPillButton(title: "New Session", symbol: "arrow.clockwise", tokens: tokens, prominent: true) {
                            session.newSession()
                            DispatchQueue.main.async { session.focus() }
                        }
                    }
                    .padding(14)
                    .background(.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
            }
            // Same surface as the AI Chat composer.
            .background(tokens.controlFill, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(session.hasFocus ? tokens.primaryText.opacity(0.35) : Color.clear, lineWidth: 1)
            )
        }
    }

    private var directoryLabel: String {
        session.directory.map(Self.abbreviate) ?? (TerminalSession.shellPath as NSString).lastPathComponent
    }

    static func abbreviate(_ path: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if path == home { return "~" }
        return path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
    }
}

/// Hosts the session's terminal view (moved here each time the tab is shown; swapped on a new session).
private struct TerminalHost: NSViewRepresentable {
    let session: TerminalSession
    /// Changes on New Session, so SwiftUI calls `updateNSView` and the new terminal is attached.
    let generation: Int

    func makeNSView(context: Context) -> FocusTrackingContainer {
        let container = FocusTrackingContainer()
        container.onFocusChange = { [weak session] focused in session?.updateFocus(focused) }
        attach(to: container)
        return container
    }

    func updateNSView(_ container: FocusTrackingContainer, context: Context) {
        if session.terminalView().superview !== container { attach(to: container) }
    }

    static func dismantleNSView(_ container: FocusTrackingContainer, coordinator: ()) {
        container.onFocusChange?(false)
    }

    private func attach(to container: FocusTrackingContainer) {
        let terminal = session.terminalView()
        container.subviews.forEach { $0.removeFromSuperview() }
        terminal.removeFromSuperview()
        terminal.frame = container.bounds
        terminal.autoresizingMask = [.width, .height]
        container.addSubview(terminal)
        container.terminal = terminal
    }
}

/// Reports whether its terminal has keyboard focus, and keeps it there: once you've been typing in
/// the terminal, focus that SwiftUI takes back while redrawing (anything other than a text field)
/// is returned to the terminal, so you can keep typing command after command.
final class FocusTrackingContainer: NSView {
    var onFocusChange: ((Bool) -> Void)?
    weak var terminal: NotchTerminalView?
    private var observation: NSKeyValueObservation?
    private var wantsTerminalFocus = false

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        observation = nil
        guard let window else {
            wantsTerminalFocus = false
            onFocusChange?(false)
            return
        }
        observation = window.observe(\.firstResponder, options: [.initial, .new]) { [weak self] window, _ in
            MainActor.assumeIsolated { self?.firstResponderChanged(in: window) }
        }
    }

    private func firstResponderChanged(in window: NSWindow) {
        let responder = window.firstResponder
        if responder is NotchTerminalView {
            wantsTerminalFocus = true
            onFocusChange?(true)
            return
        }
        onFocusChange?(false)
        // The user chose another text field: let it have focus.
        guard wantsTerminalFocus, !(responder is NSText), window.isKeyWindow else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, let terminal = self.terminal, terminal.superview === self,
                  self.window === window, window.isKeyWindow, !(window.firstResponder is NSText),
                  !(window.firstResponder is NotchTerminalView) else { return }
            window.makeFirstResponder(terminal)
        }
    }
}
