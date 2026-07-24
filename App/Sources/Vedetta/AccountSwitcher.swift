import Foundation
import VedettaKit

/// One-click global account switch: copies an account's OAuth token into
/// the shared default Keychain item (`Claude Code-credentials`), the same
/// slot `/login` writes. Every terminal that runs `claude` without
/// CLAUDE_CONFIG_DIR reads that slot, so they all follow — live, like a
/// manual re-login. Terminals pinned with CLAUDE_CONFIG_DIR stay isolated.
///
/// After the switch the slot is the single source of truth, exactly as it
/// is for /login — Vedetta FOLLOWS it, never fights it. `reconcileSlot()`
/// watches for the slot changing under us (a live session refreshing its
/// token, or the user running /login by hand), identifies the credential's
/// owner and adopts: mirrors it into the owner's namespaced item and moves
/// the active-account pointer when the owner is a different account.
enum AccountSwitcher {
    enum Result { case ok, noCredential, failed }

    private static let defaultSlotKey = "claude.defaultSlotAccount"
    private static let switchedAtKey = "claude.defaultSlotSwitchedAt"
    private static let slotUnidentifiedKey = "claude.slotUnidentified"
    static let legacyService = "Claude Code-credentials"

    static var defaultConfigDir: String {
        ClaudeAccountRegistry.canonical(NSHomeDirectory() + "/.claude")
    }

    /// Which account currently occupies the default slot (what plain
    /// `claude` resolves to). Defaults to the original ~/.claude account.
    static var activeDefaultPath: String {
        UserDefaults.standard.string(forKey: defaultSlotKey) ?? defaultConfigDir
    }

    /// When the slot last changed hands (notch switch or adopted /login).
    /// Statusline pushes older than this belong to the previous owner.
    static var lastHandoverAt: Date? {
        let stamp = UserDefaults.standard.double(forKey: switchedAtKey)
        return stamp > 0 ? Date(timeIntervalSince1970: stamp) : nil
    }

    /// True when the slot holds a credential of no registered account (the
    /// user ran /login into an account Vedetta doesn't know). While set,
    /// nobody claims the slot: usage attribution falls back to the
    /// namespaced items and the slot is never captured or overwritten
    /// implicitly.
    static var slotIsUnidentified: Bool {
        UserDefaults.standard.bool(forKey: slotUnidentifiedKey)
    }

    /// Whether this account is the one plain `claude` resolves to — the
    /// owner of the shared slot's credential chain.
    static func ownsSharedSlot(_ account: ClaudeAccount) -> Bool {
        !slotIsUnidentified
            && ClaudeAccountRegistry.canonical(account.path) == activeDefaultPath
    }

    static func namespacedService(for configDir: String) -> String {
        "\(legacyService)-\(AccountDigest.hash8(ClaudeAccountRegistry.canonical(configDir)))"
    }

    /// Blocks on the Keychain; call off the main thread.
    @discardableResult
    static func switchDefault(to account: ClaudeAccount) -> Result {
        // Never overwrite the slot before the account leaving it has a
        // durable copy — otherwise a denied backup write would lose it.
        guard ensureCurrentSlotBacked() else { return .failed }
        let source = namespacedService(for: account.path)
        guard let token = keychainReadRaw(service: source) else { return .noCredential }
        guard keychainWrite(service: legacyService, value: token) else { return .failed }
        recordHandover(to: account.path)
        return .ok
    }

    private static func recordHandover(to path: String) {
        UserDefaults.standard.set(
            ClaudeAccountRegistry.canonical(path), forKey: defaultSlotKey
        )
        UserDefaults.standard.set(
            Date().timeIntervalSince1970, forKey: switchedAtKey
        )
        UserDefaults.standard.set(false, forKey: slotUnidentifiedKey)
    }

    /// Follows the shared slot. When its content diverges from the active
    /// account's namespaced mirror, some session refreshed the token or the
    /// user re-logged in: identify the credential's owner (one profile
    /// call) and adopt — capture the fresh credential into the owner's
    /// namespaced item (so a later switch never restores a rotated, dead
    /// refresh token) and, if the owner is a different registered account,
    /// move the active pointer to it, exactly as if the user had switched.
    /// An unidentifiable slot is left completely alone. Gated on the
    /// network opt-in; call off the main thread.
    static func reconcileSlot() async {
        guard UserDefaults.standard.bool(forKey: SettingsKey.claudeNetworkRefresh) else { return }
        guard let slotRaw = keychainReadRaw(service: legacyService) else { return }
        let activePath = activeDefaultPath
        if slotRaw == keychainReadRaw(service: namespacedService(for: activePath)) {
            return   // mirror in sync — nothing changed
        }
        guard let credentials = ClaudeCredentials.parse(Data(slotRaw.utf8)),
              !credentials.isExpired(now: Date()),
              let email = await profileEmail(accessToken: credentials.accessToken)
        else { return }   // expired or offline: try again next tick
        let accounts = VedettaSetup.claudeAccounts
        guard let owner = accounts.first(where: {
            $0.email?.caseInsensitiveCompare(email) == .orderedSame
        }) else {
            UserDefaults.standard.set(true, forKey: slotUnidentifiedKey)
            return
        }
        _ = keychainWrite(service: namespacedService(for: owner.path), value: slotRaw)
        if ClaudeAccountRegistry.canonical(owner.path) == activePath {
            UserDefaults.standard.set(false, forKey: slotUnidentifiedKey)
        } else {
            recordHandover(to: owner.path)
        }
    }

    /// The account (email) that owns an access token, via /oauth/profile.
    private static func profileEmail(accessToken: String) async -> String? {
        var request = URLRequest(
            url: URL(string: "https://api.anthropic.com/api/oauth/profile")!
        )
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue(OAuthUsageProbe.userAgent, forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 15
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let account = object["account"] as? [String: Any],
              let email = account["email"] as? String else { return nil }
        return email
    }

    /// Mirrors the slot into the active account's namespaced item before a
    /// switch overwrites it. The slot is that account's LIVE chain (its
    /// sessions may have rotated the refresh token since the last mirror),
    /// so an existing-but-stale copy must be overwritten, not kept. Skipped
    /// when the slot is a stranger's credential: the switch then clobbers
    /// it exactly like /login would, but we never capture it as ours.
    private static func ensureCurrentSlotBacked() -> Bool {
        guard !slotIsUnidentified else { return true }
        guard let current = keychainReadRaw(service: legacyService) else { return true }
        return keychainWrite(
            service: namespacedService(for: activeDefaultPath), value: current
        )
    }

    // MARK: - Keychain via the `security` CLI

    static func keychainReadRaw(service: String) -> String? {
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

    static func keychainWrite(service: String, value: String) -> Bool {
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
