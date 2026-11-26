import AppKit
import SwiftUI

enum SettingsPane: String, CaseIterable, Identifiable {
    case general, appearance, modules, shortcuts, aiAgents, license

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: "General"
        case .appearance: "Appearance"
        case .modules: "Modules"
        case .shortcuts: "Shortcuts"
        case .aiAgents: "AI & Agents"
        case .license: "License"
        }
    }

    var symbolName: String {
        switch self {
        case .general: "gearshape"
        case .appearance: "paintpalette"
        case .modules: "square.grid.2x2"
        case .shortcuts: "keyboard"
        case .aiAgents: "sparkles"
        case .license: "checkmark.seal"
        }
    }

    @ViewBuilder
    var content: some View {
        switch self {
        case .general: GeneralSettingsPane()
        case .appearance: AppearanceSettingsPane()
        case .modules: ModulesSettingsPane()
        case .shortcuts: ShortcutsSettingsPane()
        case .aiAgents: AIAgentsSettingsPane()
        case .license: LicenseSettingsPane()
        }
    }
}

/// Native preferences window: toolbar-style tabs (NSTabViewController), SwiftUI panes.
final class SettingsWindowController: NSWindowController, NSWindowDelegate {
    static let contentSize = NSSize(width: 620, height: 560)

    private let tabController = NSTabViewController()

    init(services: AppServices) {
        tabController.tabStyle = .toolbar
        for pane in SettingsPane.allCases {
            let hosting = NSHostingController(
                rootView: pane.content
                    .frame(width: Self.contentSize.width, height: Self.contentSize.height)
                    .appServices(services)
            )
            hosting.sizingOptions = []
            hosting.title = pane.title
            let item = NSTabViewItem(viewController: hosting)
            item.identifier = pane.rawValue
            item.label = pane.title
            item.image = NSImage(systemSymbolName: pane.symbolName, accessibilityDescription: pane.title)
            tabController.addTabViewItem(item)
        }

        let window = NSWindow(contentViewController: tabController)
        window.styleMask = [.titled, .closable, .miniaturizable]
        window.toolbarStyle = .preference
        window.isReleasedWhenClosed = false
        window.setContentSize(Self.contentSize)
        window.center()
        super.init(window: window)
        window.delegate = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func show(_ pane: SettingsPane) {
        if let index = SettingsPane.allCases.firstIndex(of: pane) {
            tabController.selectedTabViewItemIndex = index
        }
        // An agent app must activate itself, or the window opens behind the frontmost app.
        NSApp.activate()
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }
}
