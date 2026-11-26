import AppKit
import SwiftUI

/// App lifecycle and the menu bar status item.
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    let container = DependencyContainer()
    private var statusItem: NSStatusItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard !DependencyContainer.isRunningTests else { return }

        container.start()
        installStatusItem()

        observeContinuously({ [weak self] in self?.container.settings.showsMenuBarIcon ?? true }) { [weak self] visible in
            self?.statusItem?.isVisible = visible
        }

        if container.settings.startExpanded {
            container.windowController.expandPinned(showing: container.settings.startModule)
        }
    }

    /// Relaunching the running app (Finder, Spotlight) opens Settings, the way back in when the
    /// menu bar icon is hidden.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        container.openSettings()
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        container.stop()
    }

    // MARK: Status item

    private func installStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = item.button {
            button.image = NSImage(systemSymbolName: "rectangle.topthird.inset.filled", accessibilityDescription: "NotchDeck")
            if button.image == nil { button.title = "ND" }
        }
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
        item.isVisible = container.settings.showsMenuBarIcon
        statusItem = item
    }

    /// Rebuilt on every open so titles and checkmarks always reflect current state.
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let settings = container.settings
        let license = container.licenseManager

        if let badge = license.trialBadgeText {
            let status = NSMenuItem(title: badge, action: nil, keyEquivalent: "")
            status.isEnabled = false
            menu.addItem(status)
            if !license.isUnlocked {
                menu.addItem(item("Enter License Key…", #selector(openLicenseSettings)))
            }
            menu.addItem(.separator())
        }

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

        let outline = item("Show Geometry Outline", #selector(toggleGeometryOutline))
        outline.state = settings.showsGeometryOutline ? .on : .off
        menu.addItem(outline)

        let updates = item("Check for Updates…", #selector(checkForUpdates))
        updates.isEnabled = container.updateManager.canCheckForUpdates
        menu.addItem(updates)
        menu.addItem(item("Settings…", #selector(openSettings), key: ","))

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
        container.windowController.toggleExpanded()
    }

    @objc private func selectTheme(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let theme = NotchTheme(rawValue: raw) else { return }
        container.services.themeEngine.select(theme)
    }

    @objc private func toggleGeometryOutline() {
        container.settings.showsGeometryOutline.toggle()
    }

    @objc private func checkForUpdates() {
        container.updateManager.checkForUpdates()
    }

    @objc private func openSettings() {
        container.openSettings()
    }

    @objc private func openLicenseSettings() {
        container.openSettings(.license)
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}
