import Foundation
import Testing
@testable import VedettaKit

struct ClaudeCredentialRefreshTests {
    private let raw = Data("""
    {"claudeAiOauth":{"accessToken":"old-access","refreshToken":"old-refresh",\
    "expiresAt":1000,"refreshTokenExpiresAt":2000,"scopes":["user:inference"],\
    "subscriptionType":"max","rateLimitTier":"t5"}}
    """.utf8)

    // Forma reale della risposta di /v1/oauth/token (verificata 2026-07-24).
    private let response = Data("""
    {"token_type":"Bearer","access_token":"new-access","expires_in":28800,\
    "refresh_token":"new-refresh","refresh_token_expires_in":31536000,\
    "scope":"user:inference user:profile","account":{},"organization":{}}
    """.utf8)

    @Test func mergeUpdatesTokensAndPreservesOtherFields() throws {
        let now = Date(timeIntervalSince1970: 1_753_000_000)
        let merged = try #require(ClaudeCredentialRefresh.merged(
            raw: raw, response: response, now: now
        ))
        let root = try #require(
            try JSONSerialization.jsonObject(with: merged) as? [String: Any]
        )
        let oauth = try #require(root["claudeAiOauth"] as? [String: Any])
        #expect(oauth["accessToken"] as? String == "new-access")
        #expect(oauth["refreshToken"] as? String == "new-refresh")
        // expiresAt in millisecondi epoch: now + expires_in.
        #expect(oauth["expiresAt"] as? Int == 1_753_000_000_000 + 28_800_000)
        #expect(oauth["refreshTokenExpiresAt"] as? Int
            == 1_753_000_000_000 + 31_536_000_000)
        // Campi non toccati dal refresh: preservati identici.
        #expect(oauth["subscriptionType"] as? String == "max")
        #expect(oauth["rateLimitTier"] as? String == "t5")
        #expect(oauth["scopes"] as? [String] == ["user:inference"])
    }

    @Test func mergeKeepsOldRefreshTokenWhenResponseOmitsIt() throws {
        let response = Data(
            #"{"access_token":"new-access","expires_in":28800}"#.utf8
        )
        let merged = try #require(ClaudeCredentialRefresh.merged(
            raw: raw, response: response, now: Date(timeIntervalSince1970: 0)
        ))
        let creds = try #require(ClaudeCredentials.parse(merged))
        #expect(creds.accessToken == "new-access")
        #expect(ClaudeCredentialRefresh.refreshToken(fromRaw: merged) == "old-refresh")
    }

    @Test func mergeRejectsResponseWithoutAccessToken() {
        #expect(ClaudeCredentialRefresh.merged(
            raw: raw, response: Data(#"{"error":"invalid_grant"}"#.utf8), now: Date()
        ) == nil)
        #expect(ClaudeCredentialRefresh.merged(
            raw: Data("garbage".utf8), response: response, now: Date()
        ) == nil)
    }

    @Test func extractsRefreshTokenFromStoredBlob() {
        #expect(ClaudeCredentialRefresh.refreshToken(fromRaw: raw) == "old-refresh")
        #expect(ClaudeCredentialRefresh.refreshToken(fromRaw: Data("{}".utf8)) == nil)
    }

    @Test func requestBodyCarriesGrantAndClientID() throws {
        let body = try #require(ClaudeCredentialRefresh.requestBody(refreshToken: "rt"))
        let object = try #require(
            try JSONSerialization.jsonObject(with: body) as? [String: String]
        )
        #expect(object == [
            "grant_type": "refresh_token",
            "refresh_token": "rt",
            "client_id": ClaudeCredentialRefresh.clientID,
        ])
    }
}
