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

        if terminal.termProgram == "vscode" || terminal.bundleIdentifier == "com.microsoft.VSCode" {
            if let pid = terminal.pid,
               let url = URL(string: "vscode://vedetta.terminal-focus/focus?pid=\(pid)") {
                NSWorkspace.shared.open(url)
                return
            }
        }

        if let bundleId = terminal.bundleIdentifier,
           let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleId).first {
            app.activate()
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
