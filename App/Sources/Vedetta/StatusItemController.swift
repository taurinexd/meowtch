import AppKit

/// Menu bar item: quick visibility toggle and quit.
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
}
