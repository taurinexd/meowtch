import Foundation

/// The reply Claude Code expects from a `PermissionRequest` hook.
///
/// The subtlety this type exists for: a few tools declare
/// `requiresUserInteraction` — `ExitPlanMode` and `AskUserQuestion` in CLI
/// 2.1.220 — and for those Claude Code **discards an `allow` that carries no
/// `updatedInput`** and falls back to its own terminal prompt, exactly as if
/// the notch had never answered. Approving a plan from the notch therefore
/// looked like nothing happened. Handing the tool input back is what makes
/// the decision land; it is the same move the question flow already makes
/// when it returns the chosen `answers`.
public enum PermissionDecision {
    /// Tools whose native picker Claude Code insists on unless the hook
    /// replies with data. Deliberately a small, verified list: echoing an
    /// input re-runs the permission rules against it, so a user's own deny
    /// rule could override an allow they just gave from the notch.
    public static let interactiveTools: Set<String> = ["ExitPlanMode", "AskUserQuestion"]

    public static func claudeReply(
        allow: Bool,
        message: String?,
        toolName: String,
        toolInput: [String: Any]?
    ) -> [String: Any] {
        var decision: [String: Any] = ["behavior": allow ? "allow" : "deny"]
        if let message, !allow {
            decision["message"] = message
        }
        // Only on allow: a denial that echoed the input back would read as an
        // approval of it.
        if allow, interactiveTools.contains(toolName), let toolInput {
            decision["updatedInput"] = toolInput
        }
        return [
            "hookSpecificOutput": [
                "hookEventName": "PermissionRequest",
                "decision": decision,
            ],
        ]
    }
}
