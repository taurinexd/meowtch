import AppKit
import VedettaKit

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
        let addCodexHomeItem = NSMenuItem(
            title: "Add Codex Config Directory…",
            action: #selector(addCodexHome),
            keyEquivalent: ""
        )
        addCodexHomeItem.target = self
        menu.addItem(addCodexHomeItem)
        let trustItem = NSMenuItem(
            title: "Check Codex Hook Trust…",
            action: #selector(checkCodexHookTrust),
            keyEquivalent: ""
        )
        trustItem.target = self
        menu.addItem(trustItem)
        let approvalItem = NSMenuItem(title: "Codex Approvals", action: nil, keyEquivalent: "")
        let approvalMenu = NSMenu(title: "Codex Approvals")
        let selectedMode = CodexApprovalMode(
            rawValue: UserDefaults.standard.string(forKey: "codexApprovalMode") ?? ""
        ) ?? .followFocus
        let approvalModes: [(CodexApprovalMode, String)] = [
            (.followFocus, "Follow Focus"),
            (.alwaysNotch, "Always Notch"),
            (.alwaysTerminal, "Always Terminal"),
            (.nativeCodex, "Native Codex"),
        ]
        for (mode, title) in approvalModes {
            let item = NSMenuItem(
                title: title,
                action: #selector(selectCodexApprovalMode(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = mode.rawValue
            item.state = mode == selectedMode ? .on : .off
            approvalMenu.addItem(item)
        }
        approvalItem.submenu = approvalMenu
        menu.addItem(approvalItem)
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

    @objc private func addCodexHome() {
        let picker = NSOpenPanel()
        picker.title = "Select a Codex config directory"
        picker.prompt = "Add"
        picker.canChooseDirectories = true
        picker.canChooseFiles = false
        picker.allowsMultipleSelection = false
        guard picker.runModal() == .OK, let url = picker.url else { return }
        let codexHome = VedettaSetup.registerCodexHome(url.path)
        do {
            let changed = try VedettaSetup.installCodexHooks(at: codexHome)
            NotificationCenter.default.post(name: .vedettaCodexHomesChanged, object: nil)
            if VedettaSetup.codexHooksExplicitlyDisabled(at: codexHome) {
                showAlert(
                    title: "Codex hooks disabled",
                    message: "\(codexHome.path) explicitly disables hooks. Vedetta left config.toml unchanged."
                )
            } else {
                showAlert(
                    title: "Codex config added",
                    message: changed
                        ? "Hooks installed with a backup. Open Codex in this home and use /hooks to review Vedetta."
                        : "This config directory is already registered and its hooks are current."
                )
            }
        } catch {
            showAlert(title: "Operation failed", message: error.localizedDescription, warning: true)
        }
    }

    @objc private func checkCodexHookTrust() {
        Task { @MainActor in
            var lines: [String] = []
            for codexHome in VedettaSetup.codexHomes {
                if !codexHome.isAvailable {
                    lines.append("\(codexHome.path): unavailable")
                    continue
                }
                if VedettaSetup.codexHooksExplicitlyDisabled(at: codexHome) {
                    lines.append("\(codexHome.path): disabled in config.toml")
                    continue
                }
                let client = codexHome.isDefault
                    ? CodexAppServerClient.shared
                    : CodexAppServerClient(codexHome: codexHome.path)
                let snapshot = await client.hookTrust()
                if !codexHome.isDefault { await client.shutdown() }
                let label: String
                switch snapshot.state {
                case .verified: label = "verified"
                case .manualConfirmationRequired: label = "review with /hooks"
                case .disabled: label = "disabled"
                case .unverified: label = "unverified — review with /hooks"
                case .unavailable: label = "app-server unavailable"
                }
                lines.append("\(codexHome.path): \(label)")
            }
            showAlert(title: "Codex Hook Trust", message: lines.joined(separator: "\n"))
        }
    }

    @objc private func selectCodexApprovalMode(_ sender: NSMenuItem) {
        guard let rawValue = sender.representedObject as? String,
              CodexApprovalMode(rawValue: rawValue) != nil else { return }
        UserDefaults.standard.set(rawValue, forKey: "codexApprovalMode")
        for item in sender.menu?.items ?? [] {
            item.state = item === sender ? .on : .off
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

    private func showAlert(title: String, message: String, warning: Bool = false) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        if warning { alert.alertStyle = .warning }
        alert.runModal()
    }
}
