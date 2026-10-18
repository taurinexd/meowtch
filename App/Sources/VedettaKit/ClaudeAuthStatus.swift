import Foundation

/// The identity in `claude auth status --json` output.
public struct ClaudeAuthStatus: Equatable, Sendable {
    public let loggedIn: Bool
    public let email: String?
    public let plan: String?

    public init(loggedIn: Bool, email: String?, plan: String?) {
        self.loggedIn = loggedIn
        self.email = email
        self.plan = plan
    }

    public static func parse(_ data: Data) -> ClaudeAuthStatus? {
        guard let object = try? JSONSerialization.jsonObject(with: data),
              let root = object as? [String: Any] else { return nil }
        let account = root["account"] as? [String: Any]
        return ClaudeAuthStatus(
            loggedIn: (root["loggedIn"] as? Bool) ?? false,
            email: root["email"] as? String ?? account?["email"] as? String,
            plan: root["subscriptionType"] as? String
                ?? account?["subscriptionType"] as? String
        )
    }
}
