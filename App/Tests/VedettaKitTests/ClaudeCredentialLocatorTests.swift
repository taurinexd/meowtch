import Foundation
import Testing
@testable import VedettaKit

struct ClaudeCredentialLocatorTests {
    @Test func hash8IsDeterministicHex() {
        let a = AccountDigest.hash8("/Users/x/.claude-work")
        #expect(a.count == 8)
        #expect(a.allSatisfy { $0.isHexDigit })
        #expect(a == AccountDigest.hash8("/Users/x/.claude-work"))
        #expect(a != AccountDigest.hash8("/Users/x/.claude-other"))
    }

    @Test func hash8NormalizesUnicodeNFC() {
        // "é" composto (U+00E9) vs "e"+combining acute (U+0065 U+0301):
        // stesso path logico, stesso hash.
        #expect(AccountDigest.hash8("/Users/x/caf\u{00E9}")
            == AccountDigest.hash8("/Users/x/cafe\u{0301}"))
    }

    @Test func slotOwnerReadsTheSharedSlotFirst() {
        // The account plain `claude` resolves to right now: its sessions
        // keep the shared slot fresh, so the slot is its canonical source;
        // the namespaced mirror is the fallback.
        let hash = AccountDigest.hash8("/Users/x/.claude-work")
        let candidates = ClaudeCredentialLocator.candidates(
            configDir: "/Users/x/.claude-work", ownsSharedSlot: true
        )
        #expect(candidates == [
            .keychainService("Claude Code-credentials"),
            .keychainService("Claude Code-credentials-\(hash)"),
            .credentialsFile("/Users/x/.claude-work/.credentials.json"),
        ])
    }

    @Test func nonOwnerNeverReadsTheSharedSlot() {
        // The shared slot holds someone ELSE's credential: reading it
        // would attribute that account's usage to this one (the bug the
        // user hit live on 2026-07-24).
        let hash = AccountDigest.hash8("/Users/x/.claude")
        let candidates = ClaudeCredentialLocator.candidates(
            configDir: "/Users/x/.claude", ownsSharedSlot: false
        )
        #expect(candidates == [
            .keychainService("Claude Code-credentials-\(hash)"),
            .credentialsFile("/Users/x/.claude/.credentials.json"),
        ])
    }

    @Test func parsesCredentialsJSON() throws {
        let json = """
        {"claudeAiOauth":{"accessToken":"tok-123","refreshToken":"r","expiresAt":1753350000000,"scopes":["user:inference"]}}
        """
        let creds = try #require(ClaudeCredentials.parse(Data(json.utf8)))
        #expect(creds.accessToken == "tok-123")
        // expiresAt è in millisecondi epoch.
        #expect(creds.expiresAt == Date(timeIntervalSince1970: 1_753_350_000))
        #expect(creds.isExpired(now: Date(timeIntervalSince1970: 1_753_360_000)))
        #expect(!creds.isExpired(now: Date(timeIntervalSince1970: 1_753_340_000)))
    }

    @Test func parseRejectsGarbage() {
        #expect(ClaudeCredentials.parse(Data("nope".utf8)) == nil)
        #expect(ClaudeCredentials.parse(Data("{}".utf8)) == nil)
    }
}
