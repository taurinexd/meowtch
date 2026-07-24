import AppKit
import Foundation
import VedettaKit

/// Drives the assisted "Add account" flow: derive a config dir from a
/// name, install hooks, open Terminal.app on the login command, then poll
/// `claude auth status` until the login lands and auto-fill the identity.
@MainActor
final class AccountOnboarding: ObservableObject {
    enum Phase: Equatable {
        case naming
        case awaitingLogin
        case done(email: String?, plan: String?)
        case failed(String)
    }

    @Published var name = ""
    @Published private(set) var phase: Phase = .naming

    private var pollTask: Task<Void, Never>?

    /// ~/.claude-<slug> derived from the typed name; empty when blank.
    var resolvedPath: String {
        let slug = name
            .lowercased()
            .replacingOccurrences(of: " ", with: "-")
            .filter { $0.isLetter || $0.isNumber || $0 == "-" }
        return slug.isEmpty ? "" : NSHomeDirectory() + "/.claude-" + slug
    }

    /// The command the user would run by hand (shown as a fallback).
    var manualCommand: String {
        "CLAUDE_CONFIG_DIR=\(resolvedPath) claude auth login"
    }

    var canStart: Bool {
        guard case .naming = phase else { return false }
        return !resolvedPath.isEmpty
    }

    func start() {
        let path = resolvedPath
        guard !path.isEmpty else { return }
        do {
            try FileManager.default.createDirectory(
                atPath: path, withIntermediateDirectories: true
            )
            try VedettaSetup.ensureRuntimeLayout()
            let account = VedettaSetup.registerClaudeAccount(path)
            try VedettaSetup.installClaudeHooks(at: account)
        } catch {
            phase = .failed(error.localizedDescription)
            return
        }
        guard claudeIsOnPath() else {
            phase = .failed(
                "The `claude` CLI isn't on your PATH. Install Claude Code, then run the command below."
            )
            return
        }
        openLoginTerminal(configDir: path)
        phase = .awaitingLogin
        startPolling(configDir: path)
    }

    func cancel() {
        pollTask?.cancel()
        pollTask = nil
    }

    func reset() {
        cancel()
        name = ""
        phase = .naming
    }

    // MARK: - Steps

    private func claudeIsOnPath() -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-lc", "command -v claude"]
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        guard (try? process.run()) != nil else { return false }
        process.waitUntilExit()
        return process.terminationStatus == 0
    }

    /// Opens Terminal on the login for this config dir. Uses a `.command`
    /// script opened via `open` — no Automation permission needed (unlike
    /// AppleScript `do script`, which fails silently without it). The
    /// `export` and trailing interactive shell keep CLAUDE_CONFIG_DIR set
    /// for the whole window, so any `claude` the user runs there afterward
    /// stays on this account and never rewrites the shared default login.
    private func openLoginTerminal(configDir: String) {
        let quotedDir = "'"
            + configDir.replacingOccurrences(of: "'", with: "'\\''")
            + "'"
        // `-l`: a login shell so ~/.local/bin (where `claude` lives) is on
        // PATH; the final exec leaves an interactive shell with the env set.
        let script = """
        #!/bin/zsh -l
        export CLAUDE_CONFIG_DIR=\(quotedDir)
        echo "-> Logging into this Vedetta account, isolated to $CLAUDE_CONFIG_DIR"
        echo "   Complete the login below; this window stays on this account."
        echo ""
        claude auth login
        exec zsh -il
        """
        let path = VedettaSetup.runDir + "/account-login.command"
        do {
            try FileManager.default.createDirectory(
                atPath: VedettaSetup.runDir, withIntermediateDirectories: true
            )
            try script.write(toFile: path, atomically: true, encoding: .utf8)
            chmod(path, 0o755)
        } catch {
            phase = .failed("Couldn't prepare the login: \(error.localizedDescription)")
            return
        }
        let open = Process()
        open.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        open.arguments = [path]
        try? open.run()
    }

    private func startPolling(configDir: String) {
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            // ~5 minutes at a 2s cadence.
            for _ in 0..<150 {
                try? await Task.sleep(for: .seconds(2))
                if Task.isCancelled { return }
                guard let identity = await Self.authStatus(configDir: configDir),
                      identity.loggedIn else { continue }
                await MainActor.run {
                    guard let self else { return }
                    VedettaSetup.updateStoredClaudeAccount(path: configDir) {
                        $0.email = identity.email
                        $0.subscriptionType = identity.plan
                    }
                    self.phase = .done(email: identity.email, plan: identity.plan)
                }
                return
            }
            await MainActor.run {
                guard let self, case .awaitingLogin = self.phase else { return }
                self.phase = .failed(
                    "Timed out waiting for the login. Finish it in the terminal, then use Identify on the row."
                )
            }
        }
    }

    private struct Identity {
        let loggedIn: Bool
        let email: String?
        let plan: String?
    }

    /// `claude auth status --json` for a config dir, off the main actor.
    private static func authStatus(configDir: String) async -> Identity? {
        await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/bin/zsh")
                process.arguments = ["-lc", "claude auth status --json 2>/dev/null"]
                var environment = ProcessInfo.processInfo.environment
                environment["CLAUDE_CONFIG_DIR"] = configDir
                process.environment = environment
                let pipe = Pipe()
                process.standardOutput = pipe
                process.standardError = Pipe()
                guard (try? process.run()) != nil else {
                    continuation.resume(returning: nil)
                    return
                }
                process.waitUntilExit()
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                guard let object = try? JSONSerialization.jsonObject(with: data),
                      let root = object as? [String: Any] else {
                    continuation.resume(returning: nil)
                    return
                }
                let account = root["account"] as? [String: Any]
                continuation.resume(returning: Identity(
                    loggedIn: (root["loggedIn"] as? Bool) ?? false,
                    email: root["email"] as? String ?? account?["email"] as? String,
                    plan: root["subscriptionType"] as? String
                        ?? account?["subscriptionType"] as? String
                ))
            }
        }
    }
}
