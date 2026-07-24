import CryptoKit
import Foundation

/// Claude Code namespaces its macOS Keychain item per config dir:
/// `Claude Code-credentials-<sha256(NFC(path)).hex[:8]>` (observed on
/// 2.1.218, undocumented — hence the fallback candidates).
public enum AccountDigest {
    public static func hash8(_ path: String) -> String {
        let normalized = path.precomposedStringWithCanonicalMapping
        let digest = SHA256.hash(data: Data(normalized.utf8))
        return String(digest.map { String(format: "%02x", $0) }.joined().prefix(8))
    }
}

/// Where an account's OAuth credentials may live, in probe order.
public enum ClaudeCredentialLocator {
    public enum Candidate: Equatable, Sendable {
        case keychainService(String)
        case credentialsFile(String)
    }

    public static let legacyService = "Claude Code-credentials"

    public static func candidates(configDir: String, isDefault: Bool) -> [Candidate] {
        let namespaced = "\(legacyService)-\(AccountDigest.hash8(configDir))"
        if isDefault {
            // A global account switch copies another account's token into the
            // shared `Claude Code-credentials` slot and backs the default
            // account's own token up in its namespaced item. So the default
            // account must read that backup FIRST; the shared slot (which may
            // now hold a different account) is only the pre-switch fallback.
            return [
                .keychainService(namespaced),
                .keychainService(legacyService),
                .credentialsFile(configDir + "/.credentials.json"),
            ]
        }
        return [
            .keychainService(namespaced),
            .keychainService(legacyService),
            .credentialsFile(configDir + "/.credentials.json"),
        ]
    }
}

/// The credential blob Claude Code stores (Keychain item value or
/// .credentials.json content). Only what the usage probe needs.
public struct ClaudeCredentials: Equatable, Sendable {
    public let accessToken: String
    public let expiresAt: Date?

    public init(accessToken: String, expiresAt: Date?) {
        self.accessToken = accessToken
        self.expiresAt = expiresAt
    }

    public static func parse(_ data: Data) -> ClaudeCredentials? {
        guard let object = try? JSONSerialization.jsonObject(with: data),
              let root = object as? [String: Any],
              let oauth = root["claudeAiOauth"] as? [String: Any],
              let token = oauth["accessToken"] as? String, !token.isEmpty
        else { return nil }
        var expiresAt: Date?
        if let millis = (oauth["expiresAt"] as? NSNumber)?.doubleValue {
            expiresAt = Date(timeIntervalSince1970: millis / 1000)
        }
        return ClaudeCredentials(accessToken: token, expiresAt: expiresAt)
    }

    public func isExpired(now: Date) -> Bool {
        guard let expiresAt else { return false }
        return now >= expiresAt
    }
}
