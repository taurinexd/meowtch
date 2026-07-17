import AppKit
import Foundation
import VedettaKit

/// Takes the user back to the terminal that hosts a session. For VS Code
/// the companion extension resolves the exact integrated terminal via the
/// session's process tree; other hosts get their app activated.
@MainActor
enum JumpService {
    static func jump(to session: AgentSession, terminal: TerminalInfo?) {
        guard let terminal else { return }
        let isVSCode = terminal.termProgram == "vscode"
            || terminal.bundleIdentifier == "com.microsoft.VSCode"
        let bundleId = terminal.bundleIdentifier
            ?? (isVSCode ? "com.microsoft.VSCode" : nil)

        // Raise the hosting app first — restoring minimized windows needs
        // Accessibility (the reason the original requires it too); without
        // the grant this quietly degrades to a plain activate.
        if let bundleId,
           let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleId).first {
            unminimizeIfNeeded(app: app)
            app.activate(options: [.activateAllWindows])
        }

        // Then the companion extension focuses the exact integrated
        // terminal inside the now-frontmost VS Code.
        if isVSCode, let pid = terminal.pid,
           let url = URL(string: "vscode://vedetta.terminal-focus/focus?pid=\(pid)") {
            NSWorkspace.shared.open(url)
        }
    }

    /// If the app has no visible window (all minimized), restores the
    /// minimized ones and raises the first — best effort: without a
    /// tracked windowId the exact window is the extension's job.
    private static func unminimizeIfNeeded(app: NSRunningApplication) {
        guard AXIsProcessTrusted() else { return }
        let axApp = AXUIElementCreateApplication(app.processIdentifier)
        var windowsRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &windowsRef) == .success,
              let windows = windowsRef as? [AXUIElement], !windows.isEmpty else { return }

        var minimized: [AXUIElement] = []
        var anyVisible = false
        for window in windows {
            var value: CFTypeRef?
            if AXUIElementCopyAttributeValue(window, kAXMinimizedAttribute as CFString, &value) == .success,
               (value as? Bool) == true {
                minimized.append(window)
            } else {
                anyVisible = true
            }
        }
        guard !anyVisible else { return }
        for window in minimized {
            AXUIElementSetAttributeValue(window, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
        }
        if let first = minimized.first {
            AXUIElementPerformAction(first, kAXRaiseAction as CFString)
        }
    }

    // MARK: - Companion extension install

    /// Copies the bundled VS Code extension into ~/.vscode/extensions.
    /// Idempotent per version; VS Code loads it at its next reload.
    static func installVSCodeExtension() {
        let source = Bundle.main.bundlePath + "/Contents/Resources/vscode-extension"
        let target = NSHomeDirectory() + "/.vscode/extensions/vedetta.terminal-focus-0.1.0"
        let fm = FileManager.default
        guard fm.fileExists(atPath: source), !fm.fileExists(atPath: target) else { return }
        try? fm.createDirectory(
            atPath: (target as NSString).deletingLastPathComponent,
            withIntermediateDirectories: true
        )
        try? fm.copyItem(atPath: source, toPath: target)
    }
}

/// Persists the session→terminal map across app restarts, so adopted
/// sessions keep their full row and stay jumpable (the original persists
/// the same map for the same reason).
@MainActor
enum TerminalPersistence {
    static var path: String {
        NSHomeDirectory() + "/Library/Application Support/Vedetta/session-terminals.json"
    }

    static func load(into store: SessionStore) {
        guard let data = FileManager.default.contents(atPath: path),
              let map = try? JSONDecoder().decode([String: TerminalInfo].self, from: data)
        else { return }
        for (id, info) in map {
            store.setTerminal(info, for: id)
        }
    }

    static func save(from store: SessionStore) {
        let fm = FileManager.default
        try? fm.createDirectory(
            atPath: (path as NSString).deletingLastPathComponent,
            withIntermediateDirectories: true
        )
        if let data = try? JSONEncoder().encode(store.terminals) {
            try? data.write(to: URL(fileURLWithPath: path), options: .atomic)
        }
    }
}
