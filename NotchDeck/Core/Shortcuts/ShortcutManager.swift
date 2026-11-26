import KeyboardShortcuts
import OSLog

extension KeyboardShortcuts.Name {
    static let toggleNotch = Self("toggleNotch", initial: .init(.n, modifiers: [.control, .option]))
    static let openAIChat = Self("openAIChat", initial: .init(.space, modifiers: [.option]))
    static let togglePlayPause = Self("togglePlayPause")
    static let openFileTray = Self("openFileTray")
    static let togglePomodoro = Self("togglePomodoro")
    static let toggleCameraMirror = Self("toggleCameraMirror")
    static let approveAgentRequest = Self("approveAgentRequest")
}

/// Every user-configurable global shortcut.
enum ShortcutAction: CaseIterable, Identifiable {
    case toggleNotch, openAIChat, togglePlayPause, openFileTray, togglePomodoro, toggleCameraMirror, approveAgentRequest

    var id: Self { self }

    var name: KeyboardShortcuts.Name {
        switch self {
        case .toggleNotch: .toggleNotch
        case .openAIChat: .openAIChat
        case .togglePlayPause: .togglePlayPause
        case .openFileTray: .openFileTray
        case .togglePomodoro: .togglePomodoro
        case .toggleCameraMirror: .toggleCameraMirror
        case .approveAgentRequest: .approveAgentRequest
        }
    }

    var title: String {
        switch self {
        case .toggleNotch: "Toggle Notch Expand / Collapse"
        case .openAIChat: "Open AI Chat"
        case .togglePlayPause: "Play / Pause Media"
        case .openFileTray: "Open File Tray"
        case .togglePomodoro: "Start / Pause Pomodoro"
        case .toggleCameraMirror: "Toggle Camera Mirror"
        case .approveAgentRequest: "Approve Pending Agent Request"
        }
    }

    /// The module this shortcut drives, if it isn't built yet.
    var pendingModule: NotchModule? {
        switch self {
        case .toggleNotch: nil
        case .openAIChat: .aiChat
        case .togglePlayPause: .media
        case .openFileTray: .fileTray
        case .togglePomodoro: .pomodoro
        case .toggleCameraMirror: .mirror
        case .approveAgentRequest: .agentHooks
        }
    }
}

/// Registers global hotkeys (Carbon hot keys via KeyboardShortcuts; no Accessibility permission).
final class ShortcutManager {
    private let perform: (ShortcutAction) -> Void
    private let logger = Logger(subsystem: "com.notchdeck.NotchDeck", category: "Shortcuts")

    init(perform: @escaping (ShortcutAction) -> Void) {
        self.perform = perform
    }

    func register() {
        for action in ShortcutAction.allCases {
            KeyboardShortcuts.onKeyDown(for: action.name) { [weak self] in
                self?.logger.debug("Shortcut fired: \(action.title, privacy: .public)")
                self?.perform(action)
            }
        }
    }

    static func restoreDefaults() {
        KeyboardShortcuts.reset(ShortcutAction.allCases.map(\.name))
    }
}
