import AppKit
import Observation
import SwiftTerm

/// SwiftTerm's terminal view, adapted to live in the non-activating notch panel.
final class NotchTerminalView: LocalProcessTerminalView {
    var onFontSizeChange: ((CGFloat) -> Void)?

    /// A click must give the (non-activating) panel keyboard focus so typing reaches the shell.
    override var needsPanelToBecomeKey: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// NotchDeck has no Edit menu while the notch has focus, so the usual Terminal shortcuts are
    /// handled here: ⌘C / ⌘V / ⌘A, ⌘K (clear), ⌘+ / ⌘- (text size).
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard window?.firstResponder === self,
              event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting(.shift) == .command,
              let key = event.charactersIgnoringModifiers?.lowercased() else {
            return super.performKeyEquivalent(with: event)
        }
        switch key {
        case "c": copy(self)
        case "v": paste(self)
        case "a": selectAll(self)
        case "k": getTerminal().resetToInitialState(); send(txt: "\u{0C}")   // like Terminal's Clear to Start
        case "=", "+": onFontSizeChange?(font.pointSize + 1)
        case "-": onFontSizeChange?(font.pointSize - 1)
        default: return super.performKeyEquivalent(with: event)
        }
        return true
    }
}

/// One persistent shell session for the Terminal tab: a real terminal (xterm emulation, PTY) running
/// your login shell, like Terminal.app. The session survives closing the notch; `exit` ends it and
/// New Session starts a fresh one.
@Observable
final class TerminalSession: NSObject, LocalProcessTerminalViewDelegate {
    /// Same size as the AI Chat's message text.
    static let defaultFontSize: CGFloat = 12.5
    static let fontSizes: ClosedRange<CGFloat> = 9...20

    private(set) var isRunning = false
    private(set) var hasFocus = false
    private(set) var directory: String?
    private(set) var exitCode: Int32?
    /// Bumped for every new session (the hosting view swaps in the new terminal view).
    private(set) var generation = 0

    @ObservationIgnored private var view: NotchTerminalView?
    @ObservationIgnored private var fontSize = TerminalSession.defaultFontSize

    /// The terminal view, created (and the shell started) on first use, then reused.
    func terminalView() -> NotchTerminalView {
        if let view { return view }
        let view = NotchTerminalView(frame: NSRect(x: 0, y: 0, width: 520, height: 300))
        view.processDelegate = self
        view.optionAsMetaKey = false                 // Option types special characters, as in Terminal.app
        view.font = Self.font(size: fontSize)
        view.nativeForegroundColor = NSColor(white: 0.93, alpha: 1)
        // Transparent: the rounded background behind it matches the AI Chat composer.
        view.nativeBackgroundColor = .clear
        view.caretColor = NSColor.controlAccentColor
        view.selectedTextBackgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.4)
        view.onFontSizeChange = { [weak self] size in self?.setFontSize(size) }
        self.view = view
        start(in: view)
        return view
    }

    private func start(in view: NotchTerminalView) {
        let shell = Self.shellPath
        // A leading "-" in the process name makes it a login shell (as Terminal.app does).
        view.startProcess(executable: shell, args: [], environment: Self.environment(), execName: "-" + (shell as NSString).lastPathComponent,
                          currentDirectory: FileManager.default.homeDirectoryForCurrentUser.path)
        isRunning = true
        exitCode = nil
        directory = nil
    }

    /// Ends the current shell (if it's still running) and starts a fresh one in a new terminal.
    func newSession() {
        if let old = view {
            old.processDelegate = nil            // its late "terminated" report must not mark the new one stopped
            if isRunning { old.process.terminate() }
            old.removeFromSuperview()
        }
        view = nil
        isRunning = false
        generation += 1
        _ = terminalView()
    }

    /// Kept for callers that restart after `exit`.
    func restart() { newSession() }

    /// Gives the terminal keyboard focus (the panel must already be able to become key).
    func focus() {
        guard let view, let window = view.window else { return }
        window.makeKey()
        window.makeFirstResponder(view)
    }

    /// Set by the hosting view, which watches its window's first responder.
    func updateFocus(_ focused: Bool) {
        if hasFocus != focused { hasFocus = focused }
    }

    func setFontSize(_ size: CGFloat) {
        fontSize = min(max(size, Self.fontSizes.lowerBound), Self.fontSizes.upperBound)
        view?.font = Self.font(size: fontSize)
    }

    // MARK: LocalProcessTerminalViewDelegate

    func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}

    /// The shell retitles the window on every command; not shown (it only caused redraws).
    func setTerminalTitle(source: LocalProcessTerminalView, title: String) {}

    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {
        let path = directory.flatMap { URL(string: $0)?.path ?? $0 }
        if self.directory != path { self.directory = path }
    }

    func processTerminated(source: TerminalView, exitCode: Int32?) {
        guard source === view else { return }
        isRunning = false
        self.exitCode = exitCode.map(Self.decodeExitStatus)
    }

    /// SwiftTerm sometimes reports the raw `waitpid` status: exit code in bits 8–15 when the low
    /// 7 bits (the terminating signal) are 0.
    nonisolated static func decodeExitStatus(_ status: Int32) -> Int32 {
        status & 0x7F == 0 ? (status >> 8) & 0xFF : status
    }

    // MARK: Environment

    nonisolated static var shellPath: String {
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        return FileManager.default.isExecutableFile(atPath: shell) ? shell : "/bin/zsh"
    }

    /// NotchDeck's environment (as launched by launchd) plus what terminals set. The login shell then
    /// builds PATH etc. from your shell startup files, as in Terminal.app.
    nonisolated static func environment() -> [String] {
        var env = ProcessInfo.processInfo.environment
        env["TERM"] = "xterm-256color"
        env["COLORTERM"] = "truecolor"
        env["TERM_PROGRAM"] = "NotchDeck"
        if env["LANG"] == nil { env["LANG"] = "en_US.UTF-8" }
        env["HOME"] = FileManager.default.homeDirectoryForCurrentUser.path
        // Variables that only make sense for NotchDeck's own process.
        for key in ["XPC_SERVICE_NAME", "__CFBundleIdentifier", "OS_ACTIVITY_DT_MODE"] { env[key] = nil }
        return env.map { "\($0.key)=\($0.value)" }
    }

    /// The system font's monospaced design (SF Mono): same family as the rest of NotchDeck, but with
    /// fixed-width columns, which a terminal needs.
    private static func font(size: CGFloat) -> NSFont {
        NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
    }
}
