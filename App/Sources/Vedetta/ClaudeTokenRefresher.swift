import Foundation
import VedettaKit

/// Keeps non-active accounts' credentials alive. The account that owns the
/// shared slot is refreshed by its own live sessions; every OTHER account
/// has no session running, so its access token would expire (~8h) and its
/// usage would freeze — the bug the user hit. Vedetta is the sole owner of
/// those credential chains, so it may rotate them safely: same refresh
/// grant the CLI uses, result written back to the account's namespaced
/// Keychain item. Refreshes only actually-expired tokens (never rotates a
/// live one) and never touches the slot owner's chain.
enum ClaudeTokenRefresher {
    private actor Gate {
        private var inFlight: Set<String> = []
        func begin(_ key: String) -> Bool { inFlight.insert(key).inserted }
        func end(_ key: String) { inFlight.remove(key) }
    }

    private static let gate = Gate()

    /// Refreshes `account`'s namespaced credential if it is expired (or
    /// about to be). Returns true when a fresh credential was written, so
    /// the caller can re-read and retry its request.
    static func refreshExpiredCredential(for account: ClaudeAccount) async -> Bool {
        guard UserDefaults.standard.bool(forKey: SettingsKey.claudeNetworkRefresh),
              !AccountSwitcher.ownsSharedSlot(account) else { return false }
        let service = AccountSwitcher.namespacedService(for: account.path)
        guard await gate.begin(service) else { return false }
        defer { Task { await gate.end(service) } }

        guard let raw = AccountSwitcher.keychainReadRaw(service: service),
              let credentials = ClaudeCredentials.parse(Data(raw.utf8)),
              credentials.isExpired(now: Date().addingTimeInterval(120)),
              let refreshToken = ClaudeCredentialRefresh.refreshToken(fromRaw: Data(raw.utf8)),
              let body = ClaudeCredentialRefresh.requestBody(refreshToken: refreshToken)
        else { return false }

        var request = URLRequest(url: ClaudeCredentialRefresh.endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(OAuthUsageProbe.userAgent, forHTTPHeaderField: "User-Agent")
        request.httpBody = body
        request.timeoutInterval = 20
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let merged = ClaudeCredentialRefresh.merged(raw: Data(raw.utf8), response: data, now: Date()),
              let mergedText = String(data: merged, encoding: .utf8)
        else { return false }

        // If something else (a pinned-terminal session logging in) wrote
        // the item while our request ran, keep that newer credential: it
        // is a fresh chain, ours is now the stale one.
        guard AccountSwitcher.keychainReadRaw(service: service) == raw else { return true }
        return AccountSwitcher.keychainWrite(service: service, value: mergedText)
    }
}
