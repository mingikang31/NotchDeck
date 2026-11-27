import Foundation
import Testing
@testable import NotchDeck

struct SettingsStoreTests {
    private func freshDefaults() -> UserDefaults {
        let name = "NotchDeckTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    @Test func defaultsMatchTheSpec() {
        let store = SettingsStore(defaults: freshDefaults())
        #expect(store.hoverDelayMilliseconds == 150)
        #expect(store.hoverCloseDelayMilliseconds == 200)
        #expect(store.theme == .classicBlack)
        #expect(store.displayPolicy == .notchDisplay)
        #expect(store.autoCollapse == .pointerExit)
        #expect(store.showsMenuBarIcon)
        #expect(store.agentServerPort == 47823)
        #expect(store.enabledModules == NotchModule.allCases)
    }

    @Test func valuesPersistAndAreClamped() {
        let defaults = freshDefaults()
        let store = SettingsStore(defaults: defaults)
        store.theme = .frostedGlass
        store.hoverCloseDelayMilliseconds = 5000
        #expect(store.hoverCloseDelayMilliseconds == 500)
        store.hoverCloseDelayMilliseconds = -5
        #expect(store.hoverCloseDelayMilliseconds == 0)
        store.hoverDelayMilliseconds = 900
        store.agentServerPort = 80
        store.displayPolicy = .followActiveScreen
        #expect(store.hoverDelayMilliseconds == 500)

        let reloaded = SettingsStore(defaults: defaults)
        #expect(reloaded.theme == .frostedGlass)
        #expect(reloaded.hoverDelayMilliseconds == 500)
        #expect(reloaded.hoverCloseDelayMilliseconds == 0)
        #expect(reloaded.agentServerPort == 1024)
        #expect(reloaded.displayPolicy == .followActiveScreen)
    }

    @Test func moduleOrderAndEnablementPersist() {
        let defaults = freshDefaults()
        let store = SettingsStore(defaults: defaults)
        store.modules.move(fromOffsets: IndexSet(integer: 2), toOffset: 0) // AI Chat first
        store.modules[1].isEnabled = false                                  // disable Media

        let reloaded = SettingsStore(defaults: defaults)
        #expect(reloaded.modules.first?.module == .aiChat)
        #expect(!reloaded.enabledModules.contains(.media))
    }

    @Test func reconcileAppendsNewModulesAndDropsDuplicates() {
        let stored = [
            ModuleConfiguration(module: .calendar, isEnabled: false),
            ModuleConfiguration(module: .media, isEnabled: true),
            ModuleConfiguration(module: .calendar, isEnabled: true),
        ]
        let result = ModuleConfiguration.reconciled(stored)
        #expect(result.count == NotchModule.allCases.count)
        #expect(result[0] == ModuleConfiguration(module: .calendar, isEnabled: false))
        #expect(result[1].module == .media)
        #expect(Set(result.map(\.module)) == Set(NotchModule.allCases))
    }
}
