import Foundation
import VedettaKit

/// Resolves and runs the `claude` CLI from a Finder-launched app, whose
/// PATH is launchd's bare one. Never rely on `zsh -lc "claude …"` finding
/// it: the native installer adds ~/.local/bin to PATH in .zshrc only.
enum ClaudeCLI {
    /// Absolute path to `claude`, or nil when it isn't installed. Known
    /// install locations first; then an interactive login shell (which
    /// does read .zshrc) for custom setups. Blocks; call off the main
    /// thread when the fallback may run.
    static func resolve() -> String? {
        if let hit = ClaudeCLILocator.firstKnownInstall(
            home: NSHomeDirectory(),
            isExecutable: FileManager.default.isExecutableFile(atPath:)
        ) {
            return hit
        }
        let shell = Process()
        shell.executableURL = URL(fileURLWithPath: "/bin/zsh")
        shell.arguments = ["-ilc", "command -v claude"]
        shell.standardInput = FileHandle.nullDevice
        let output = Pipe()
        shell.standardOutput = output
        shell.standardError = Pipe()
        guard (try? shell.run()) != nil else { return nil }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        shell.waitUntilExit()
        guard let path = ClaudeCLILocator.parseCommandV(String(decoding: data, as: UTF8.self)),
              FileManager.default.isExecutableFile(atPath: path) else { return nil }
        return path
    }

    /// `zsh -lc` arguments that run the resolved binary by absolute path,
    /// with its directory prepended to PATH (an npm install's `env node`
    /// shebang finds the node that sits next to it).
    static func shellArguments(_ binary: String, _ arguments: String) -> [String] {
        let dir = shellQuote((binary as NSString).deletingLastPathComponent)
        return ["-lc", "PATH=\(dir):$PATH \(shellQuote(binary)) \(arguments)"]
    }

    /// `claude auth status --json` for a config dir. The default account
    /// must run with CLAUDE_CONFIG_DIR unset: setting it — even to the
    /// default path — makes Claude Code look up a namespaced Keychain item,
    /// which the default account (credential stored un-suffixed) doesn't
    /// have. Blocks; call off the main thread.
    static func authStatus(configDir: String, isDefault: Bool) -> ClaudeAuthStatus? {
        guard let claude = resolve() else { return nil }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = shellArguments(claude, "auth status --json 2>/dev/null")
        var environment = ProcessInfo.processInfo.environment
        if isDefault {
            environment.removeValue(forKey: "CLAUDE_CONFIG_DIR")
        } else {
            environment["CLAUDE_CONFIG_DIR"] = configDir
        }
        process.environment = environment
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        guard (try? process.run()) != nil else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return ClaudeAuthStatus.parse(data)
    }

    /// Whether `auth status` speaks for this account. Not for the default
    /// one while another account holds the shared slot: the CLI then mixes
    /// the email cached in ~/.claude.json (the last real login) with the
    /// plan of the switched-in token — seen live on 2026-10-18 as
    /// dev@… + "team".
    static func canIdentify(_ account: ClaudeAccount) -> Bool {
        !account.isDefault || AccountSwitcher.ownsSharedSlot(account)
    }

    /// Fills in email/plan for registered accounts that have none — the
    /// default row included, which nothing else ever identifies. Silent on
    /// failure; the row keeps its Identify button. Call off the main thread.
    static func backfillIdentities(where include: (ClaudeAccount) -> Bool = { _ in true }) {
        for account in VedettaSetup.claudeAccounts
        where account.email == nil && account.isAvailable && canIdentify(account)
            && include(account) {
            guard let status = authStatus(
                configDir: account.path, isDefault: account.isDefault
            ), status.loggedIn, status.email != nil else { continue }
            DispatchQueue.main.async {
                VedettaSetup.updateStoredClaudeAccount(path: account.path) {
                    $0.email = status.email
                    $0.subscriptionType = status.plan
                }
            }
        }
    }

    static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
