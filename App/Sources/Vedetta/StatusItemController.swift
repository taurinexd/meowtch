import AppKit
import VedettaKit

/// Menu bar item, kept minimal per macOS convention: panel toggle up top,
/// Settings and Quit at the bottom. Everything operational (hooks,
/// approvals, sounds, display) lives in the Settings window.
@MainActor
final class StatusItemController {
    private let statusItem: NSStatusItem
    private let panelController: NotchPanelController

    init(panelController: NotchPanelController) {
        self.panelController = panelController
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)

        if let button = statusItem.button {
            button.image = NSImage(
                systemSymbolName: "binoculars.fill",
                accessibilityDescription: "Vedetta"
            )
        }

        let menu = NSMenu()
        let toggleItem = NSMenuItem(
            title: "Show/Hide Panel",
            action: #selector(togglePanel),
            keyEquivalent: ""
        )
        toggleItem.target = self
        menu.addItem(toggleItem)

        menu.addItem(.separator())
        let settingsItem = NSMenuItem(
            title: "Settings…",
            action: #selector(openSettings),
            keyEquivalent: ","
        )
        settingsItem.target = self
        menu.addItem(settingsItem)

        menu.addItem(.separator())
        let quitItem = NSMenuItem(
            title: "Quit Vedetta",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )
        menu.addItem(quitItem)
        statusItem.menu = menu
    }

    @objc private func togglePanel() {
        panelController.toggleVisibility()
    }

    @objc private func openSettings() {
        SettingsWindowController.shared.show()
    }
}
