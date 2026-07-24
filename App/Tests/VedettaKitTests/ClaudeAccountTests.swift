import Foundation
import Testing
@testable import VedettaKit

struct ClaudeAccountTests {
    @Test func defaultAccountIsAlwaysFirst() {
        let accounts = ClaudeAccountRegistry.resolve(
            defaultPath: "/Users/x/.claude",
            stored: [StoredClaudeAccount(path: "/Users/x/.claude-work")],
            directoryExists: { _ in true }
        )
        #expect(accounts.count == 2)
        #expect(accounts[0].isDefault)
        #expect(accounts[0].path == "/Users/x/.claude")
        #expect(!accounts[1].isDefault)
    }

    @Test func canonicalizesAndDeduplicates() {
        let accounts = ClaudeAccountRegistry.resolve(
            defaultPath: "/Users/x/.claude",
            stored: [
                StoredClaudeAccount(path: "/Users/x/.claude/"),          // duplica il default
                StoredClaudeAccount(path: "/Users/x/foo/../.claude-b"),  // da canonicalizzare
            ],
            directoryExists: { _ in true }
        )
        #expect(accounts.map(\.path) == ["/Users/x/.claude", "/Users/x/.claude-b"])
    }

    @Test func storedMetadataSurvivesResolve() {
        let accounts = ClaudeAccountRegistry.resolve(
            defaultPath: "/Users/x/.claude",
            stored: [StoredClaudeAccount(
                path: "/Users/x/.claude-b", alias: "Work",
                email: "w@x.com", subscriptionType: "max"
            )],
            directoryExists: { $0 == "/Users/x/.claude-b" }
        )
        #expect(accounts[1].alias == "Work")
        #expect(accounts[1].email == "w@x.com")
        #expect(accounts[1].subscriptionType == "max")
        #expect(accounts[1].isAvailable)
        #expect(!accounts[0].isAvailable)   // la dir default qui non esiste
    }

    @Test func defaultAccountPicksUpStoredMetadata() {
        // A stored record for the default path carries its alias/email onto
        // the synthesized default account (and must not duplicate it).
        let accounts = ClaudeAccountRegistry.resolve(
            defaultPath: "/Users/x/.claude",
            stored: [StoredClaudeAccount(
                path: "/Users/x/.claude/", alias: "Tools",
                email: "t@x.com", subscriptionType: "max"
            )],
            directoryExists: { _ in true }
        )
        #expect(accounts.count == 1)
        #expect(accounts[0].isDefault)
        #expect(accounts[0].alias == "Tools")
        #expect(accounts[0].email == "t@x.com")
        #expect(accounts[0].displayName == "Tools")
    }

    @Test func settingsPathAndDisplayName() {
        let account = ClaudeAccount(
            path: "/Users/x/.claude-b", alias: nil, email: "w@x.com",
            subscriptionType: nil, isDefault: false, isAvailable: true
        )
        #expect(account.settingsPath == "/Users/x/.claude-b/settings.json")
        #expect(account.displayName == "w@x.com")
        let anonymous = ClaudeAccount(
            path: "/Users/x/.claude-b", alias: nil, email: nil,
            subscriptionType: nil, isDefault: false, isAvailable: true
        )
        #expect(anonymous.displayName == ".claude-b")
    }
}
