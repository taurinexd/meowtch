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

        let installItem = NSMenuItem(
            title: "Install Claude Code Hooks…",
            action: #selector(installHooks),
            keyEquivalent: ""
        )
        installItem.target = self
        menu.addItem(installItem)
        let removeItem = NSMenuItem(
            title: "Remove Claude Code Hooks",
            action: #selector(removeHooks),
            keyEquivalent: ""
        )
        removeItem.target = self
        menu.addItem(removeItem)
        let muteItem = NSMenuItem(
            title: "Mute Sounds",
            action: #selector(toggleMute),
            keyEquivalent: ""
        )
        muteItem.target = self
        muteItem.state = SoundEngine.shared.isMuted ? .on : .off
        menu.addItem(muteItem)
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

    @objc private func toggleMute(_ sender: NSMenuItem) {
        SoundEngine.shared.isMuted.toggle()
        sender.state = SoundEngine.shared.isMuted ? .on : .off
    }

    @objc private func installHooks() {
        report {
            try VedettaSetup.ensureRuntimeLayout()
            let changed = try VedettaSetup.installClaudeHooks()
            return changed
                ? "Hook installati (backup in ~/.vedetta/backups).\nValgono per le sessioni Claude Code avviate da ora in poi."
                : "Hook già installati, nessuna modifica."
        }
    }

    @objc private func removeHooks() {
        report {
            let changed = try VedettaSetup.removeClaudeHooks()
            return changed
                ? "Hook rimossi (backup in ~/.vedetta/backups)."
                : "Nessun hook Vedetta presente."
        }
    }

    private func report(_ work: () throws -> String) {
        let alert = NSAlert()
        do {
            alert.messageText = "Vedetta"
            alert.informativeText = try work()
        } catch {
            alert.alertStyle = .warning
            alert.messageText = "Operazione fallita"
            alert.informativeText = error.localizedDescription
        }
        alert.runModal()
    }
}
