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

struct ClaudeCredentialOwnerTests {
    private func account(_ path: String, _ email: String?, _ plan: String?) -> ClaudeAccount {
        ClaudeAccount(path: path, alias: nil, email: email, subscriptionType: plan,
                      isDefault: false, isAvailable: true)
    }

    private var accounts: [ClaudeAccount] {
        [
            account("/u/.claude", "tools@x.net", "max"),
            account("/u/.claude-tech", "tech@x.net", "max"),
            account("/u/.claude-team", "tools@x.net", "team"),
        ]
    }

    @Test func uniqueEmailResolvesRegardlessOfPlan() {
        let owner = ClaudeCredentialOwner.resolve(email: "TECH@x.net", plan: nil, accounts: accounts)
        #expect(owner?.path == "/u/.claude-tech")
    }

    @Test func sharedEmailTeamTokenGoesToTeamAccountNotFirstMatch() {
        let owner = ClaudeCredentialOwner.resolve(email: "tools@x.net", plan: "team", accounts: accounts)
        #expect(owner?.path == "/u/.claude-team")
    }

    @Test func sharedEmailPersonalTokenGoesToPersonalAccount() {
        let owner = ClaudeCredentialOwner.resolve(email: "tools@x.net", plan: "max", accounts: accounts)
        #expect(owner?.path == "/u/.claude")
    }

    @Test func sharedEmailWithoutPlanIsAmbiguous() {
        #expect(ClaudeCredentialOwner.resolve(email: "tools@x.net", plan: nil, accounts: accounts) == nil)
    }

    @Test func sharedEmailAndPlanIsAmbiguous() {
        let twins = accounts + [account("/u/.claude-team2", "tools@x.net", "team")]
        #expect(ClaudeCredentialOwner.resolve(email: "tools@x.net", plan: "team", accounts: twins) == nil)
    }

    @Test func unknownEmailHasNoOwner() {
        #expect(ClaudeCredentialOwner.resolve(email: "nobody@x.net", plan: "max", accounts: accounts) == nil)
    }
}
