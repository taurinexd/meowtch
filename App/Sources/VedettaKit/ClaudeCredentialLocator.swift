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

    /// The shared `Claude Code-credentials` slot belongs to exactly one
    /// account at a time — whichever one plain `claude` resolves to (the
    /// default, or the account a global switch put there). That owner reads
    /// the slot FIRST: live sessions keep it fresh. Every other account
    /// reads ONLY its namespaced item — falling back to the slot would
    /// return someone else's credential and misattribute their usage.
    public static func candidates(configDir: String, ownsSharedSlot: Bool) -> [Candidate] {
        let namespaced = "\(legacyService)-\(AccountDigest.hash8(configDir))"
        if ownsSharedSlot {
            return [
                .keychainService(legacyService),
                .keychainService(namespaced),
                .credentialsFile(configDir + "/.credentials.json"),
            ]
        }
        return [
            .keychainService(namespaced),
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
