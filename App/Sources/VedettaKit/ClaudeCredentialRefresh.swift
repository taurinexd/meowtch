import Foundation

/// The OAuth refresh grant Claude Code itself uses. Endpoint and client id
/// extracted from the CLI binary (2.1.218) and verified live on 2026-07-24:
/// POST {grant_type, refresh_token, client_id} → 200 with access_token,
/// refresh_token, expires_in, refresh_token_expires_in (+account/org info).
/// Pure request/response logic — Keychain and HTTP live in the app target.
public enum ClaudeCredentialRefresh {
    public static let endpoint = URL(string: "https://api.anthropic.com/v1/oauth/token")!
    public static let clientID = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"

    public static func requestBody(refreshToken: String) -> Data? {
        try? JSONSerialization.data(withJSONObject: [
            "grant_type": "refresh_token",
            "refresh_token": refreshToken,
            "client_id": clientID,
        ])
    }

    public static func refreshToken(fromRaw raw: Data) -> String? {
        guard let root = try? JSONSerialization.jsonObject(with: raw) as? [String: Any],
              let oauth = root["claudeAiOauth"] as? [String: Any],
              let token = oauth["refreshToken"] as? String, !token.isEmpty
        else { return nil }
        return token
    }

    /// Merges a token response into the stored credential blob: updates
    /// accessToken / refreshToken / expiresAt / refreshTokenExpiresAt and
    /// preserves every other field (scopes, subscriptionType, tier, …),
    /// so the blob stays exactly what the CLI expects to read back.
    public static func merged(raw: Data, response: Data, now: Date) -> Data? {
        guard var root = try? JSONSerialization.jsonObject(with: raw) as? [String: Any],
              var oauth = root["claudeAiOauth"] as? [String: Any],
              let reply = try? JSONSerialization.jsonObject(with: response) as? [String: Any],
              let access = reply["access_token"] as? String, !access.isEmpty
        else { return nil }
        oauth["accessToken"] = access
        if let refresh = reply["refresh_token"] as? String, !refresh.isEmpty {
            oauth["refreshToken"] = refresh
        }
        let nowMS = now.timeIntervalSince1970 * 1000
        if let expiresIn = (reply["expires_in"] as? NSNumber)?.doubleValue {
            oauth["expiresAt"] = Int((nowMS + expiresIn * 1000).rounded())
        }
        if let refreshIn = (reply["refresh_token_expires_in"] as? NSNumber)?.doubleValue {
            oauth["refreshTokenExpiresAt"] = Int((nowMS + refreshIn * 1000).rounded())
        }
        root["claudeAiOauth"] = oauth
        return try? JSONSerialization.data(withJSONObject: root)
    }
}
