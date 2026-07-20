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
            raise(
                app: app,
                windowId: terminal.windowId,
                directoryName: session.directoryName,
                trace: &trace
            )
        } else {
            trace.append("app-not-running")
        }

        // Then the companion extension focuses the exact integrated
        // terminal. The URI is delivered to the FOCUSED window's extension
        // host, and the extension only sees its own window's terminals:
        // give the raise a beat so it lands in the session's window (the
        // workspace param lets a wrong window no-op harmlessly). The pid
        // list is the ancestry captured at hook time — it includes the
        // terminal's live shell; the bridge pid alone is dead by now.
        let pids = terminal.pidChain ?? terminal.pid.map { [Int($0)] } ?? []
        if isVSCode, !pids.isEmpty {
            let pidParams = pids.map { "pid=\($0)" }.joined(separator: "&")
            let workspace = session.directory.addingPercentEncoding(
                withAllowedCharacters: .urlQueryAllowed
            ) ?? ""
            if let url = URL(string: "vscode://vedetta.terminal-focus/focus?\(pidParams)&workspace=\(workspace)") {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                    NSWorkspace.shared.open(url)
                }
                trace.append("uri-scheduled pids=\(pids.count)")
            }
        }
    }

    /// Brings the session's window to the front. Plain activate() from a
    /// background, never-active caller is IGNORED by cooperative
    /// activation on modern macOS: the reliable road is Accessibility
    /// (AXRaise + frontmost), the same reason the original requires that
    /// permission. The right window is matched by title — VS Code titles
    /// carry the folder name ("file — folder") — and gets restored when
    /// minimized, even while other windows stay visible.
    private static func raise(
        app: NSRunningApplication,
        windowId: Int?,
        directoryName: String,
        trace: inout [String]
    ) {
        guard AXIsProcessTrusted() else {
            trace.append("ax-untrusted")
            app.activate()
            return
        }
        let axApp = AXUIElementCreateApplication(app.processIdentifier)
        var windowsRef: CFTypeRef?
        let err = AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &windowsRef)
        let windows = (windowsRef as? [AXUIElement]) ?? []
        trace.append("axWindows=\(err == .success ? "\(windows.count)" : "err\(err.rawValue)")")

        func title(_ window: AXUIElement) -> String {
            var value: CFTypeRef?
            AXUIElementCopyAttributeValue(window, kAXTitleAttribute as CFString, &value)
            return (value as? String) ?? ""
        }
        func isMinimized(_ window: AXUIElement) -> Bool {
            var value: CFTypeRef?
            return AXUIElementCopyAttributeValue(window, kAXMinimizedAttribute as CFString, &value) == .success
                && (value as? Bool) == true
        }

        // The exact window first: the bridge recorded its CGWindowID at
        // hook time. AX exposes no window id, so match by frame against
        // the window-list entry (same top-left global coordinates).
        var target: AXUIElement?
        if let windowId {
            if let bounds = cgWindowBounds(windowId) {
                target = windows.first { window in
                    guard let frame = axFrame(window) else { return false }
                    return abs(frame.origin.x - bounds.origin.x) < 3
                        && abs(frame.origin.y - bounds.origin.y) < 3
                        && abs(frame.width - bounds.width) < 3
                        && abs(frame.height - bounds.height) < 3
                }
                trace.append(target != nil
                    ? "byWindowId=\(windowId)"
                    : "noAxMatch cg=(\(Int(bounds.origin.x)),\(Int(bounds.origin.y)) \(Int(bounds.width))x\(Int(bounds.height)))")
            } else {
                trace.append("cgBounds=nil id=\(windowId)")
            }
        }

        // Title fallback: exact segment first ("vedetta" must not grab
        // the "vedetta-wt-topic" window), contains as a last resort.
        let name = directoryName.lowercased()
        if target == nil, !name.isEmpty {
            target = windows.first { window in
                title(window).lowercased()
                    .components(separatedBy: " — ")
                    .contains { $0 == name }
            } ?? windows.first { title($0).lowercased().contains(name) }
            if let target { trace.append("matched=\(title(target).prefix(40))") }
        }
        if target == nil {
            target = windows.first { !isMinimized($0) } ?? windows.first
            trace.append("fallback")
        }

        if let target {
            if isMinimized(target) {
                AXUIElementSetAttributeValue(target, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
                trace.append("restored")
            }
            AXUIElementPerformAction(target, kAXRaiseAction as CFString)
        }
        let front = AXUIElementSetAttributeValue(axApp, kAXFrontmostAttribute as CFString, kCFBooleanTrue)
        trace.append("axFront=\(front.rawValue)")
        app.activate()
    }

    /// Bounds of a window by CGWindowID (works for minimized ones too,
    /// returning their last on-screen frame).
    private static func cgWindowBounds(_ windowId: Int) -> CGRect? {
        let ids = [CGWindowID(windowId)] as CFArray
        guard let list = CGWindowListCreateDescriptionFromArray(ids) as? [[String: Any]],
              let entry = list.first,
              let dict = entry[kCGWindowBounds as String] as? [String: Any],
              let bounds = CGRect(dictionaryRepresentation: dict as CFDictionary)
        else { return nil }
        return bounds
    }

    private static func axFrame(_ window: AXUIElement) -> CGRect? {
        var positionRef: CFTypeRef?
        var sizeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, kAXPositionAttribute as CFString, &positionRef) == .success,
              AXUIElementCopyAttributeValue(window, kAXSizeAttribute as CFString, &sizeRef) == .success
        else { return nil }
        var origin = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(positionRef as! AXValue, .cgPoint, &origin),
              AXValueGetValue(sizeRef as! AXValue, .cgSize, &size) else { return nil }
        return CGRect(origin: origin, size: size)
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
        let extensionsDir = NSHomeDirectory() + "/.vscode/extensions"
        let target = extensionsDir + "/vedetta.terminal-focus-0.6.0"
        let fm = FileManager.default
        // Outdated versions go away so VS Code always loads the current one.
        for stale in [
            "vedetta.terminal-focus-0.1.0", "vedetta.terminal-focus-0.2.0",
            "vedetta.terminal-focus-0.3.0", "vedetta.terminal-focus-0.4.0", "vedetta.terminal-focus-0.4.1",
            "vedetta.terminal-focus-0.4.2", "vedetta.terminal-focus-0.4.3", "vedetta.terminal-focus-0.5.0",
        ] {
            try? fm.removeItem(atPath: extensionsDir + "/" + stale)
        }
        guard fm.fileExists(atPath: source), !fm.fileExists(atPath: target) else { return }
        try? fm.createDirectory(atPath: extensionsDir, withIntermediateDirectories: true)
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
