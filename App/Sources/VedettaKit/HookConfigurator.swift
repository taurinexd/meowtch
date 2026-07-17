import Foundation

/// Pure logic for installing/removing Vedetta's hooks inside a Claude Code
/// `settings.json` dictionary. Merge is strictly additive and idempotent:
/// the user's own hooks and every unrelated key survive untouched.
/// The defensive command shape mirrors what the original ships: if the
/// bridge is gone the hook is a silent no-op and Claude Code never breaks.
public enum HookConfigurator {
    /// Substring that identifies our entries inside command strings.
    public static let markerToken = "vedetta-bridge"

    /// Events Vedetta subscribes to in M2 (PermissionRequest arrives in M3).
    public static let claudeEvents = [
        "SessionStart", "SessionEnd", "UserPromptSubmit",
        "PreToolUse", "PostToolUse", "Notification",
        "Stop", "SubagentStart", "SubagentStop",
    ]

    /// Tool-scoped events need an explicit wildcard matcher.
    private static let matcherEvents: Set<String> = [
        "PreToolUse", "PostToolUse", "Notification",
    ]

    public static func bridgeCommand(source: String = "claude") -> String {
        #"/bin/sh -c '[ -x "$HOME/.vedetta/bin/vedetta-bridge" ] && "$HOME/.vedetta/bin/vedetta-bridge" --source \#(source); exit 0'"#
    }

    // MARK: - Merge

    public static func mergingHooks(into settings: [String: Any]) -> ([String: Any], changed: Bool) {
        var settings = settings
        var hooks = settings["hooks"] as? [String: Any] ?? [:]
        var changed = false

        for event in claudeEvents {
            var groups = hooks[event] as? [[String: Any]] ?? []
            guard !containsMarker(groups) else { continue }
            var group: [String: Any] = [
                "hooks": [["type": "command", "command": bridgeCommand()]]
            ]
            if matcherEvents.contains(event) {
                group["matcher"] = "*"
            }
            groups.append(group)
            hooks[event] = groups
            changed = true
        }

        settings["hooks"] = hooks
        return (settings, changed)
    }

    // MARK: - Remove

    public static func removingHooks(from settings: [String: Any]) -> ([String: Any], changed: Bool) {
        var settings = settings
        guard var hooks = settings["hooks"] as? [String: Any] else { return (settings, false) }
        var changed = false

        for (event, value) in hooks {
            guard let groups = value as? [[String: Any]] else { continue }
            let kept = groups.filter { !groupHasMarker($0) }
            if kept.count != groups.count {
                changed = true
                if kept.isEmpty {
                    hooks.removeValue(forKey: event)
                } else {
                    hooks[event] = kept
                }
            }
        }

        if hooks.isEmpty {
            settings.removeValue(forKey: "hooks")
        } else {
            settings["hooks"] = hooks
        }
        return (settings, changed)
    }

    // MARK: - State

    public static func isInstalled(in settings: [String: Any]) -> Bool {
        guard let hooks = settings["hooks"] as? [String: Any] else { return false }
        return claudeEvents.allSatisfy { event in
            containsMarker(hooks[event] as? [[String: Any]] ?? [])
        }
    }

    // MARK: - Internals

    private static func containsMarker(_ groups: [[String: Any]]) -> Bool {
        groups.contains(where: groupHasMarker)
    }

    private static func groupHasMarker(_ group: [String: Any]) -> Bool {
        guard let entries = group["hooks"] as? [[String: Any]] else { return false }
        return entries.contains {
            ($0["command"] as? String)?.contains(markerToken) == true
        }
    }
}
