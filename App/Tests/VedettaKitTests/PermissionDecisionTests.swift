import Foundation
import Testing
@testable import VedettaKit

struct PermissionDecisionTests {
    private func decision(_ reply: [String: Any]) -> [String: Any]? {
        (reply["hookSpecificOutput"] as? [String: Any])?["decision"] as? [String: Any]
    }

    @Test func replyCarriesTheHookEventName() {
        let reply = PermissionDecision.claudeReply(
            allow: true, message: nil, toolName: "Bash", toolInput: ["command": "ls"]
        )
        let output = reply["hookSpecificOutput"] as? [String: Any]
        #expect(output?["hookEventName"] as? String == "PermissionRequest")
    }

    /// The regression: approving a plan from the notch used to send a bare
    /// `allow`, which Claude Code DISCARDS for a tool that requires user
    /// interaction — the terminal asked again as if nobody had answered.
    @Test func approvingAPlanEchoesTheToolInputBack() {
        let input: [String: Any] = ["plan": "# Piano", "planFilePath": "/tmp/p.md"]
        let reply = PermissionDecision.claudeReply(
            allow: true, message: nil, toolName: "ExitPlanMode", toolInput: input
        )
        let decision = decision(reply)
        #expect(decision?["behavior"] as? String == "allow")
        let updated = decision?["updatedInput"] as? [String: Any]
        #expect(updated?["plan"] as? String == "# Piano")
        #expect(updated?["planFilePath"] as? String == "/tmp/p.md")
    }

    /// A malformed AskUserQuestion falls through to the generic approval bar;
    /// it needs the same echo, for the same reason.
    @Test func approvingAQuestionEchoesTheToolInputBack() {
        let reply = PermissionDecision.claudeReply(
            allow: true, message: nil, toolName: "AskUserQuestion", toolInput: ["questions": []]
        )
        #expect(decision(reply)?["updatedInput"] != nil)
    }

    /// Ordinary tools keep the bare allow: echoing an input re-runs the
    /// permission rules against it, and a deny rule would then override the
    /// user's own decision.
    @Test func approvingAnOrdinaryToolStaysBare() {
        let reply = PermissionDecision.claudeReply(
            allow: true, message: nil, toolName: "Bash", toolInput: ["command": "rm -rf /"]
        )
        let decision = decision(reply)
        #expect(decision?["behavior"] as? String == "allow")
        #expect(decision?["updatedInput"] == nil)
    }

    /// A denial is honoured whatever the tool, and must never smuggle an
    /// input back — that would read as an approval of it.
    @Test func denyingAPlanCarriesTheMessageOnly() {
        let reply = PermissionDecision.claudeReply(
            allow: false, message: "keep planning", toolName: "ExitPlanMode",
            toolInput: ["plan": "# Piano"]
        )
        let decision = decision(reply)
        #expect(decision?["behavior"] as? String == "deny")
        #expect(decision?["message"] as? String == "keep planning")
        #expect(decision?["updatedInput"] == nil)
    }

    /// Nothing to echo: the reply stays a bare allow rather than shipping an
    /// empty object Claude Code would validate against the tool schema.
    @Test func missingToolInputStaysBare() {
        let reply = PermissionDecision.claudeReply(
            allow: true, message: nil, toolName: "ExitPlanMode", toolInput: nil
        )
        #expect(decision(reply)?["updatedInput"] == nil)
    }

    @Test func replySerialisesToJSON() {
        let reply = PermissionDecision.claudeReply(
            allow: true, message: nil, toolName: "ExitPlanMode", toolInput: ["plan": "# Piano"]
        )
        #expect(JSONSerialization.isValidJSONObject(reply))
    }
}
