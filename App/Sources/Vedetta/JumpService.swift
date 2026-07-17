import AppKit
import Foundation
import VedettaKit

/// Takes the user back to the terminal that hosts a session. For VS Code
/// the companion extension resolves the exact integrated terminal via the
/// session's process tree; other hosts get their app activated.
@MainActor
enum JumpService {
    static func jump(to session: AgentSession, terminal: TerminalInfo?) {
        var trace = ["jump \(session.id.prefix(8))"]
        defer { log(trace.joined(separator: " ")) }

        guard let terminal else {
            trace.append("NO-TERMINAL")
            return
        }
        let isVSCode = terminal.termProgram == "vscode"
            || terminal.bundleIdentifier == "com.microsoft.VSCode"
        let bundleId = terminal.bundleIdentifier
            ?? (isVSCode ? "com.microsoft.VSCode" : nil)
        trace.append("bundle=\(bundleId ?? "nil") pid=\(terminal.pid.map(String.init) ?? "-") ax=\(AXIsProcessTrusted())")

        if let bundleId,
           let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleId).first {
            raise(app: app, trace: &trace)
        } else {
            trace.append("app-not-running")
        }

        // Then the companion extension focuses the exact integrated
        // terminal inside the now-frontmost VS Code.
        if isVSCode, let pid = terminal.pid,
           let url = URL(string: "vscode://vedetta.terminal-focus/focus?pid=\(pid)") {
            NSWorkspace.shared.open(url)
            trace.append("uri-opened")
        }
    }

    /// Brings the app to the front. Plain activate() from a background,
    /// never-active caller is IGNORED by cooperative activation on modern
    /// macOS: the reliable road is Accessibility (AXRaise + frontmost),
    /// the same reason the original requires that permission. Restores
    /// minimized windows when none is visible (best effort: without a
    /// tracked windowId the exact window is the extension's job).
    private static func raise(app: NSRunningApplication, trace: inout [String]) {
        if AXIsProcessTrusted() {
            let axApp = AXUIElementCreateApplication(app.processIdentifier)
            var windowsRef: CFTypeRef?
            let err = AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &windowsRef)
            let windows = (windowsRef as? [AXUIElement]) ?? []
            trace.append("axWindows=\(err == .success ? "\(windows.count)" : "err\(err.rawValue)")")

            var target: AXUIElement?
            var minimized: [AXUIElement] = []
            for window in windows {
                var value: CFTypeRef?
                if AXUIElementCopyAttributeValue(window, kAXMinimizedAttribute as CFString, &value) == .success,
                   (value as? Bool) == true {
                    minimized.append(window)
                } else if target == nil {
                    target = window
                }
            }
            if target == nil, !minimized.isEmpty {
                for window in minimized {
                    AXUIElementSetAttributeValue(window, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
                }
                target = minimized.first
                trace.append("restored=\(minimized.count)")
            }
            if let target {
                AXUIElementPerformAction(target, kAXRaiseAction as CFString)
            }
            let front = AXUIElementSetAttributeValue(axApp, kAXFrontmostAttribute as CFString, kCFBooleanTrue)
            trace.append("axFront=\(front.rawValue)")
        } else {
            trace.append("ax-untrusted")
        }
        app.activate(options: [.activateAllWindows])
    }

    private static func log(_ line: String) {
        let stamped = ISO8601DateFormatter().string(from: Date()) + " " + line + "\n"
        let path = NSHomeDirectory() + "/.vedetta/run/jump.log"
        if let handle = FileHandle(forWritingAtPath: path) {
            handle.seekToEndOfFile()
            handle.write(Data(stamped.utf8))
            try? handle.close()
        } else {
            try? stamped.write(toFile: path, atomically: true, encoding: .utf8)
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
