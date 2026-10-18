import Foundation
import Testing
@testable import VedettaKit

struct ClaudeAuthStatusTests {
    @Test func parsesTopLevelIdentity() {
        // Shape of `claude auth status --json` on 2.1.302.
        let json = #"{"loggedIn":true,"authMethod":"claude.ai","email":"a@b.c","subscriptionType":"team"}"#
        let status = ClaudeAuthStatus.parse(Data(json.utf8))
        #expect(status == ClaudeAuthStatus(loggedIn: true, email: "a@b.c", plan: "team"))
    }

    @Test func fallsBackToTheNestedAccount() {
        let json = #"{"loggedIn":true,"account":{"email":"a@b.c","subscriptionType":"max"}}"#
        #expect(ClaudeAuthStatus.parse(Data(json.utf8))
            == ClaudeAuthStatus(loggedIn: true, email: "a@b.c", plan: "max"))
    }

    @Test func loggedOutAndGarbage() {
        #expect(ClaudeAuthStatus.parse(Data(#"{"loggedIn":false}"#.utf8))?.loggedIn == false)
        #expect(ClaudeAuthStatus.parse(Data("command not found".utf8)) == nil)
    }
}
