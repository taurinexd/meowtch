import Foundation

/// One Claude Code account = one config dir (CLAUDE_CONFIG_DIR). The
/// default ~/.claude is always present and not removable; extra accounts
/// are user-registered. `path` (canonical) is the stable identity.
public struct ClaudeAccount: Equatable, Sendable, Identifiable {
    public let path: String
    public var alias: String?
    public var email: String?
    public var subscriptionType: String?
    public let isDefault: Bool
    public let isAvailable: Bool

    public init(
        path: String, alias: String?, email: String?,
        subscriptionType: String?, isDefault: Bool, isAvailable: Bool
    ) {
        self.path = path
        self.alias = alias
        self.email = email
        self.subscriptionType = subscriptionType
        self.isDefault = isDefault
        self.isAvailable = isAvailable
    }

    public var id: String { path }
    public var settingsPath: String { path + "/settings.json" }

    /// Alias if set, else email, else the directory name.
    public var displayName: String {
        if let alias, !alias.isEmpty { return alias }
        if let email, !email.isEmpty { return email }
        return (path as NSString).lastPathComponent
    }
}

/// The persisted record (UserDefaults JSON) behind a registered account.
public struct StoredClaudeAccount: Codable, Equatable, Sendable {
    public var path: String
    public var alias: String?
    public var email: String?
    public var subscriptionType: String?

    public init(
        path: String, alias: String? = nil,
        email: String? = nil, subscriptionType: String? = nil
    ) {
        self.path = path
        self.alias = alias
        self.email = email
        self.subscriptionType = subscriptionType
    }
}

public enum ClaudeAccountRegistry {
    public static func resolve(
        defaultPath: String,
        stored: [StoredClaudeAccount],
        directoryExists: (String) -> Bool
    ) -> [ClaudeAccount] {
        let canonicalDefault = canonical(defaultPath)
        var seen: Set<String> = [canonicalDefault]
        // The default account may carry stored metadata (alias/email) too,
        // even though it is never removable.
        let defaultRecord = stored.first { canonical($0.path) == canonicalDefault }
        var accounts = [ClaudeAccount(
            path: canonicalDefault, alias: defaultRecord?.alias,
            email: defaultRecord?.email,
            subscriptionType: defaultRecord?.subscriptionType, isDefault: true,
            isAvailable: directoryExists(canonicalDefault)
        )]
        for record in stored {
            let path = canonical(record.path)
            guard !path.isEmpty, seen.insert(path).inserted else { continue }
            accounts.append(ClaudeAccount(
                path: path, alias: record.alias, email: record.email,
                subscriptionType: record.subscriptionType, isDefault: false,
                isAvailable: directoryExists(path)
            ))
        }
        return accounts
    }

    public static func canonical(_ path: String) -> String {
        (path as NSString).standardizingPath
    }
}
