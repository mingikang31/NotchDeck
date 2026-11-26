import AppKit

/// App lifecycle and the menu bar status item.
/// (Global hotkeys and the Sparkle updater are wired in Phase 2.)
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var container: DependencyContainer?
    private var statusItem: NSStatusItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard !DependencyContainer.isRunningTests else { return }

        let container = DependencyContainer()
        self.container = container
        container.windowController.start()
        installStatusItem()

        if container.settings.startExpanded {
            container.windowController.expandPinned()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        container?.windowController.stop()
    }

    // MARK: Status item

    private func installStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = item.button {
            button.image = NSImage(
                systemSymbolName: "rectangle.topthird.inset.filled",
                accessibilityDescription: "NotchDeck"
            )
            if button.image == nil { button.title = "ND" }
        }
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
        statusItem = item
    }

    /// Rebuilt on every open so checkmarks always reflect current state.
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        guard let container else { return }
        let settings = container.settings

        let toggleTitle = container.windowController.isAnyExpanded ? "Collapse Notch" : "Expand Notch"
        menu.addItem(item(toggleTitle, #selector(toggleNotch)))
        menu.addItem(.separator())

        menu.addItem(.sectionHeader(title: "Theme"))
        for theme in NotchTheme.allCases {
            let entry = item(theme.displayName, #selector(selectTheme(_:)))
            entry.representedObject = theme.rawValue
            entry.state = settings.theme == theme ? .on : .off
            menu.addItem(entry)
        }
        menu.addItem(.separator())

        let sizeMenu = NSMenu()
        for preset in NotchSizePreset.allCases {
            let entry = item(preset.displayName, #selector(selectSizePreset(_:)))
            entry.representedObject = preset.rawValue
            entry.state = settings.sizePreset == preset ? .on : .off
            sizeMenu.addItem(entry)
        }
        let sizeItem = NSMenuItem(title: "Expanded Size", action: nil, keyEquivalent: "")
        sizeItem.submenu = sizeMenu
        menu.addItem(sizeItem)

        let displayMenu = NSMenu()
        for policy in DisplayPolicy.allCases {
            let entry = item(policy.displayName, #selector(selectDisplayPolicy(_:)))
            entry.representedObject = policy.rawValue
            entry.state = settings.displayPolicy == policy ? .on : .off
            displayMenu.addItem(entry)
        }
        let displayItem = NSMenuItem(title: "Displays", action: nil, keyEquivalent: "")
        displayItem.submenu = displayMenu
        menu.addItem(displayItem)

        let outline = item("Show Geometry Outline", #selector(toggleGeometryOutline))
        outline.state = settings.showsGeometryOutline ? .on : .off
        menu.addItem(outline)

        menu.addItem(.separator())
        menu.addItem(item("Quit NotchDeck", #selector(quit), key: "q"))
    }

    private func item(_ title: String, _ action: Selector, key: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        return item
    }

    // MARK: Actions

    @objc private func toggleNotch() {
        container?.windowController.toggleExpanded()
    }

    @objc private func selectTheme(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let theme = NotchTheme(rawValue: raw) else { return }
        container?.themeEngine.select(theme)
    }

    @objc private func selectSizePreset(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let preset = NotchSizePreset(rawValue: raw),
              let container else { return }
        container.settings.sizePreset = preset
        container.windowController.rebuildPanels()
    }

    @objc private func selectDisplayPolicy(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let policy = DisplayPolicy(rawValue: raw),
              let container else { return }
        container.settings.displayPolicy = policy
        container.windowController.rebuildPanels()
    }

    @objc private func toggleGeometryOutline() {
        container?.settings.showsGeometryOutline.toggle()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}
