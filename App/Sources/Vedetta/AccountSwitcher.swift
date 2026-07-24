import Foundation
import VedettaKit

/// One-click global account switch: copies an account's OAuth token into
/// the shared default Keychain item (`Claude Code-credentials`), the same
/// slot `/login` writes. Every terminal that runs `claude` without
/// CLAUDE_CONFIG_DIR reads that slot, so they all follow — live, like a
/// manual re-login. Terminals pinned with CLAUDE_CONFIG_DIR stay isolated.
///
/// The default account keeps its token ONLY in the shared slot, so before
/// the first switch we mirror it into its own namespaced item; otherwise
/// overwriting the slot would erase it. After that one-time backup every
/// account has a durable copy and every switch is reversible.
enum AccountSwitcher {
    enum Result { case ok, noCredential, failed }

    private static let defaultSlotKey = "claude.defaultSlotAccount"
    private static let legacyService = "Claude Code-credentials"

    static var defaultConfigDir: String {
        ClaudeAccountRegistry.canonical(NSHomeDirectory() + "/.claude")
    }

    /// Which account currently occupies the default slot (what plain
    /// `claude` resolves to). Defaults to the original ~/.claude account.
    static var activeDefaultPath: String {
        UserDefaults.standard.string(forKey: defaultSlotKey) ?? defaultConfigDir
    }

    private static func namespacedService(for configDir: String) -> String {
        "\(legacyService)-\(AccountDigest.hash8(ClaudeAccountRegistry.canonical(configDir)))"
    }

    /// Blocks on the Keychain; call off the main thread.
    @discardableResult
    static func switchDefault(to account: ClaudeAccount) -> Result {
        ensureDefaultBackup()
        let source = namespacedService(for: account.path)
        guard let token = keychainReadRaw(service: source) else { return .noCredential }
        guard keychainWrite(service: legacyService, value: token) else { return .failed }
        UserDefaults.standard.set(
            ClaudeAccountRegistry.canonical(account.path), forKey: defaultSlotKey
        )
        return .ok
    }

    /// One-time: give the original default account its own namespaced item
    /// mirroring the current slot, so switching away isn't destructive.
    /// A no-op once the backup exists (or if the slot is empty).
    private static func ensureDefaultBackup() {
        let backup = namespacedService(for: defaultConfigDir)
        guard keychainReadRaw(service: backup) == nil else { return }
        guard let current = keychainReadRaw(service: legacyService) else { return }
        _ = keychainWrite(service: backup, value: current)
    }

    // MARK: - Keychain via the `security` CLI

    private static func keychainReadRaw(service: String) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = [
            "find-generic-password", "-s", service, "-a", NSUserName(), "-w",
        ]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        guard (try? process.run()) != nil else { return nil }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        let output = pipe.fileHandleForReading.readDataToEndOfFile()
        let text = String(data: output, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        // The credential is JSON text; `security -w` returns it verbatim.
        return (text?.isEmpty == false) ? text : nil
    }

    private static func keychainWrite(service: String, value: String) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        // -U updates the item if it already exists. The value is passed as
        // one argument (no shell), so JSON braces/quotes need no escaping.
        process.arguments = [
            "add-generic-password", "-U", "-s", service, "-a", NSUserName(), "-w", value,
        ]
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        guard (try? process.run()) != nil else { return false }
        process.waitUntilExit()
        return process.terminationStatus == 0
    }
}
