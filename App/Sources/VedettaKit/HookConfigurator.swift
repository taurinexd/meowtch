import Foundation

/// Pure logic for installing/removing Vedetta's hooks inside Claude Code's
/// `settings.json` and Codex's `hooks.json`. Merge is strictly additive and idempotent:
/// the user's own hooks and every unrelated key survive untouched.
/// The defensive command shape mirrors what the original ships: if the
/// bridge is gone the hook is a silent no-op and the coding agent never breaks.
public enum HookConfigurator {
    /// Substring that identifies our entries inside command strings.
    public static let markerToken = "vedetta-bridge"

    /// Events Vedetta subscribes to.
    public static let claudeEvents = [
        "SessionStart", "SessionEnd", "UserPromptSubmit",
        "PreToolUse", "PostToolUse", "Notification",
        "Stop", "StopFailure", "SubagentStart", "SubagentStop",
        "PermissionRequest", "PreCompact",
    ]

    /// Exact Codex event set observed in Vibe Island 1.0.42's embedded
    /// manifest and installed hooks.json.
    public static let codexEvents = [
        "SessionStart", "UserPromptSubmit", "PermissionRequest",
        "PostToolUse", "SubagentStop", "Stop",
    ]

    /// Tool-scoped events need an explicit wildcard matcher.
    private static let matcherEvents: Set<String> = [
        "PreToolUse", "PostToolUse", "Notification", "PermissionRequest",
    ]

    /// The approval hook blocks until the user decides from the notch:
    /// its timeout (seconds) is the upper bound on that wait, after which
    /// Claude Code falls back to its normal terminal prompt.
    public static let blockingTimeouts: [String: Int] = [
        "PermissionRequest": 86_400
    ]

    private static let codexTimeouts: [String: Int] = Dictionary(
        uniqueKeysWithValues: codexEvents.map { event in
            (event, event == "PermissionRequest" ? 7_200 : 5)
        }
    )

    public static func bridgeCommand(source: String = "claude") -> String {
        #"/bin/sh -c '[ -x "$HOME/.vedetta/bin/vedetta-bridge" ] && "$HOME/.vedetta/bin/vedetta-bridge" --source \#(source); exit 0'"#
    }

    // MARK: - Merge

    public static func mergingHooks(into settings: [String: Any]) -> ([String: Any], changed: Bool) {
        mergingHooks(
            into: settings,
            events: claudeEvents,
            source: "claude",
            matchers: Dictionary(uniqueKeysWithValues: matcherEvents.map { ($0, "*") }),
            timeouts: blockingTimeouts
        )
    }

    public static func mergingCodexHooks(
        into settings: [String: Any]
    ) -> ([String: Any], changed: Bool) {
        mergingHooks(
            into: settings,
            events: codexEvents,
            source: "codex",
            matchers: ["PostToolUse": ""],
            timeouts: codexTimeouts
        )
    }

    private static func mergingHooks(
        into settings: [String: Any],
        events: [String],
        source: String,
        matchers: [String: String],
        timeouts: [String: Int]
    ) -> ([String: Any], changed: Bool) {
        var settings = settings
        var hooks = settings["hooks"] as? [String: Any] ?? [:]
        var changed = false

        for event in events {
            var groups = hooks[event] as? [[String: Any]] ?? []
            guard !containsMarker(groups, source: source) else { continue }
            var entry: [String: Any] = [
                "type": "command",
                "command": bridgeCommand(source: source),
            ]
            if let timeout = timeouts[event] {
                entry["timeout"] = timeout
            }
            var group: [String: Any] = ["hooks": [entry]]
            if let matcher = matchers[event] {
                group["matcher"] = matcher
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
        removingHooks(from: settings, source: "claude")
    }

    public static func removingCodexHooks(
        from settings: [String: Any]
    ) -> ([String: Any], changed: Bool) {
        removingHooks(from: settings, source: "codex")
    }

    private static func removingHooks(
        from settings: [String: Any],
        source: String
    ) -> ([String: Any], changed: Bool) {
        var settings = settings
        guard var hooks = settings["hooks"] as? [String: Any] else { return (settings, false) }
        var changed = false

        for (event, value) in hooks {
            guard let groups = value as? [[String: Any]] else { continue }
            let kept = groups.filter { !groupHasMarker($0, source: source) }
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

    // MARK: - StatusLine (usage harvest)

    /// Claude Code feeds the statusline JSON that includes `rate_limits`:
    /// harvesting it gives quota data with zero API calls. Installed only
    /// when the user has no statusline of their own — never clobbered.
    /// Claims the single statusLine slot when it is free, already ours, or
    /// held by a command whose executable is gone — `canReplace` reports
    /// that last case (an orphan left behind by an uninstalled app). A
    /// live foreign statusLine (the user's own, or the original while it is
    /// installed) is never clobbered.
    public static func installingStatusLine(
        into settings: [String: Any],
        command: String,
        canReplace: (String) -> Bool = { _ in false }
    ) -> ([String: Any], changed: Bool) {
        var settings = settings
        if let existing = settings["statusLine"] as? [String: Any] {
            let existingCommand = existing["command"] as? String ?? ""
            if existingCommand.contains(markerToken) { return (settings, false) }
            guard canReplace(existingCommand) else { return (settings, false) }
        }
        settings["statusLine"] = ["type": "command", "command": command]
        return (settings, true)
    }

    public static func removingStatusLine(
        from settings: [String: Any]
    ) -> ([String: Any], changed: Bool) {
        var settings = settings
        guard let statusLine = settings["statusLine"] as? [String: Any],
              (statusLine["command"] as? String)?.contains("vedetta") == true
        else { return (settings, false) }
        settings.removeValue(forKey: "statusLine")
        return (settings, true)
    }

    // MARK: - State

    public static func isInstalled(in settings: [String: Any]) -> Bool {
        guard let hooks = settings["hooks"] as? [String: Any] else { return false }
        return claudeEvents.allSatisfy { event in
            containsMarker(hooks[event] as? [[String: Any]] ?? [], source: "claude")
        }
    }

    public static func codexHooksInstalled(in settings: [String: Any]) -> Bool {
        guard let hooks = settings["hooks"] as? [String: Any] else { return false }
        return codexEvents.allSatisfy { event in
            containsMarker(hooks[event] as? [[String: Any]] ?? [], source: "codex")
        }
    }

    /// True when at least one of our hooks is present: distinguishes "the
    /// user installed us, now some events drifted" (heal) from "never
    /// installed / deliberately uninstalled" (leave alone).
    public static func hasAnyHook(in settings: [String: Any]) -> Bool {
        guard let hooks = settings["hooks"] as? [String: Any] else { return false }
        return claudeEvents.contains { event in
            containsMarker(hooks[event] as? [[String: Any]] ?? [], source: "claude")
        }
    }

    public static func hasAnyCodexHook(in settings: [String: Any]) -> Bool {
        guard let hooks = settings["hooks"] as? [String: Any] else { return false }
        return codexEvents.contains { event in
            containsMarker(hooks[event] as? [[String: Any]] ?? [], source: "codex")
        }
    }

    // MARK: - Internals

    private static func containsMarker(
        _ groups: [[String: Any]],
        source: String
    ) -> Bool {
        groups.contains { groupHasMarker($0, source: source) }
    }

    private static func groupHasMarker(
        _ group: [String: Any],
        source: String
    ) -> Bool {
        guard let entries = group["hooks"] as? [[String: Any]] else { return false }
        return entries.contains {
            guard let command = $0["command"] as? String else { return false }
            return command.contains(markerToken) && command.contains("--source \(source)")
        }
    }
}
