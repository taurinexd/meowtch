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
            action: #selector(installClaudeHooks),
            keyEquivalent: ""
        )
        installItem.target = self
        menu.addItem(installItem)
        let removeItem = NSMenuItem(
            title: "Remove Claude Code Hooks",
            action: #selector(removeClaudeHooks),
            keyEquivalent: ""
        )
        removeItem.target = self
        menu.addItem(removeItem)
        let installCodexItem = NSMenuItem(
            title: "Install Codex Hooks…",
            action: #selector(installCodexHooks),
            keyEquivalent: ""
        )
        installCodexItem.target = self
        menu.addItem(installCodexItem)
        let removeCodexItem = NSMenuItem(
            title: "Remove Codex Hooks",
            action: #selector(removeCodexHooks),
            keyEquivalent: ""
        )
        removeCodexItem.target = self
        menu.addItem(removeCodexItem)
        let muteItem = NSMenuItem(
            title: "Mute Sounds",
            action: #selector(toggleMute),
            keyEquivalent: ""
        )
        muteItem.target = self
        muteItem.state = SoundEngine.shared.isMuted ? .on : .off
        menu.addItem(muteItem)
        let axItem = NSMenuItem(
            title: "Enable Terminal Titles (Accessibility)…",
            action: #selector(requestAccessibility),
            keyEquivalent: ""
        )
        axItem.target = self
        axItem.state = AXIsProcessTrusted() ? .on : .off
        menu.addItem(axItem)
        let displayItem = NSMenuItem(
            title: "Panel on External Display",
            action: #selector(toggleDisplay),
            keyEquivalent: ""
        )
        displayItem.target = self
        displayItem.state = NotchPanelController.preferExternalDisplay ? .on : .off
        menu.addItem(displayItem)
        let onboardingItem = NSMenuItem(
            title: "Show Onboarding",
            action: #selector(showOnboarding),
            keyEquivalent: ""
        )
        onboardingItem.target = self
        menu.addItem(onboardingItem)
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

    @objc private func requestAccessibility(_ sender: NSMenuItem) {
        // Prompts the system dialog and registers the app in the
        // Accessibility list; used to read terminal tab titles.
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        sender.state = AXIsProcessTrusted() ? .on : .off
    }

    @objc private func toggleDisplay(_ sender: NSMenuItem) {
        NotchPanelController.preferExternalDisplay.toggle()
        sender.state = NotchPanelController.preferExternalDisplay ? .on : .off
        panelController.relocate()
    }

    @objc private func showOnboarding() {
        OnboardingController.shared.show()
    }

    @objc private func toggleMute(_ sender: NSMenuItem) {
        SoundEngine.shared.isMuted.toggle()
        sender.state = SoundEngine.shared.isMuted ? .on : .off
    }

    @objc private func installClaudeHooks() {
        report {
            try VedettaSetup.ensureRuntimeLayout()
            let changed = try VedettaSetup.installClaudeHooks()
            return changed
                ? "Hook Claude Code installati (backup in ~/.vedetta/backups)."
                : "Hook Claude Code già installati, nessuna modifica."
        }
    }

    @objc private func removeClaudeHooks() {
        report {
            let changed = try VedettaSetup.removeClaudeHooks()
            return changed
                ? "Hook Claude Code rimossi (backup in ~/.vedetta/backups)."
                : "Nessun hook Claude Code di Vedetta presente."
        }
    }

    @objc private func installCodexHooks() {
        report {
            try VedettaSetup.ensureRuntimeLayout()
            let changed = try VedettaSetup.installCodexHooks()
            return changed
                ? "Hook Codex installati (backup in ~/.vedetta/backups).\nAl prossimo avvio Codex, verifica e autorizza Vedetta con /hooks."
                : "Hook Codex già installati, nessuna modifica."
        }
    }

    @objc private func removeCodexHooks() {
        report {
            let changed = try VedettaSetup.removeCodexHooks()
            return changed
                ? "Hook Codex rimossi (backup in ~/.vedetta/backups)."
                : "Nessun hook Codex di Vedetta presente."
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
