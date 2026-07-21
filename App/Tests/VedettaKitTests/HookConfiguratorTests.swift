import Testing
import Foundation
@testable import VedettaKit

struct HookConfiguratorTests {

    /// A settings.json shaped like a real user's: existing sound hooks
    /// that must survive untouched, plus unrelated top-level keys.
    private func userSettings() -> [String: Any] {
        [
            "model": "claude-fable-5[1m]",
            "theme": "dark",
            "hooks": [
                "Stop": [
                    [
                        "hooks": [
                            ["type": "command", "command": "afplay /System/Library/Sounds/Glass.aiff", "async": true]
                        ]
                    ]
                ],
            ],
        ]
    }

    @Test func mergeInstallsAllEvents() {
        let (merged, changed) = HookConfigurator.mergingHooks(into: [:])
        #expect(changed)
        let hooks = merged["hooks"] as? [String: Any]
        #expect(hooks != nil)
        for event in HookConfigurator.claudeEvents {
            #expect(hooks?[event] != nil, "manca \(event)")
        }
    }

    @Test func mergePreservesUserHooksAndKeys() {
        let (merged, changed) = HookConfigurator.mergingHooks(into: userSettings())
        #expect(changed)
        #expect(merged["model"] as? String == "claude-fable-5[1m]")
        #expect(merged["theme"] as? String == "dark")
        let stopGroups = (merged["hooks"] as? [String: Any])?["Stop"] as? [[String: Any]]
        #expect(stopGroups?.count == 2)
        let firstCommand = ((stopGroups?[0]["hooks"] as? [[String: Any]])?[0]["command"]) as? String
        #expect(firstCommand?.contains("afplay") == true)
    }

    @Test func mergeIsIdempotent() {
        let (once, _) = HookConfigurator.mergingHooks(into: userSettings())
        let (twice, changedAgain) = HookConfigurator.mergingHooks(into: once)
        #expect(!changedAgain)
        let stopGroups = (twice["hooks"] as? [String: Any])?["Stop"] as? [[String: Any]]
        #expect(stopGroups?.count == 2)
    }

    @Test func isInstalledReflectsState() {
        #expect(!HookConfigurator.isInstalled(in: userSettings()))
        let (merged, _) = HookConfigurator.mergingHooks(into: userSettings())
        #expect(HookConfigurator.isInstalled(in: merged))
    }

    @Test func removeStripsOnlyOurHooks() {
        let (merged, _) = HookConfigurator.mergingHooks(into: userSettings())
        let (removed, changed) = HookConfigurator.removingHooks(from: merged)
        #expect(changed)
        #expect(!HookConfigurator.isInstalled(in: removed))
        let stopGroups = (removed["hooks"] as? [String: Any])?["Stop"] as? [[String: Any]]
        #expect(stopGroups?.count == 1)
        let cmd = ((stopGroups?[0]["hooks"] as? [[String: Any]])?[0]["command"]) as? String
        #expect(cmd?.contains("afplay") == true)
        // gli eventi che restano vuoti vengono rimossi del tutto
        let hooks = removed["hooks"] as? [String: Any]
        #expect(hooks?["PreToolUse"] == nil)
    }

    @Test func hasAnyHookDistinguishesDriftFromUninstalled() {
        // Never installed: no vedetta hook at all.
        #expect(!HookConfigurator.hasAnyHook(in: userSettings()))
        // Drift: installed once, then one event lost its hook (e.g. a new
        // event shipped later). isInstalled false, but hasAnyHook true.
        var (merged, _) = HookConfigurator.mergingHooks(into: userSettings())
        var hooks = merged["hooks"] as! [String: Any]
        hooks["PreCompact"] = nil
        merged["hooks"] = hooks
        #expect(!HookConfigurator.isInstalled(in: merged))
        #expect(HookConfigurator.hasAnyHook(in: merged))
        // Re-merge heals only the missing event, leaving the rest intact.
        let (healed, changed) = HookConfigurator.mergingHooks(into: merged)
        #expect(changed)
        #expect(HookConfigurator.isInstalled(in: healed))
    }

    @Test func statusLineClaimsFreeAndOrphanSlotsButSparesLiveForeign() {
        let ours = "/Users/x/.vedetta/bin/vedetta-statusline"
        // Free slot: we take it.
        let (a, ca) = HookConfigurator.installingStatusLine(into: [:], command: ours)
        #expect(ca)
        #expect(((a["statusLine"] as? [String: Any])?["command"] as? String) == ours)
        // Already ours: idempotent no-op.
        let (_, cb) = HookConfigurator.installingStatusLine(into: a, command: ours)
        #expect(!cb)
        // Live foreign statusLine: never clobbered (canReplace says no).
        let foreign = ["statusLine": ["type": "command", "command": "/opt/other/statusline"]]
        let (c, cc) = HookConfigurator.installingStatusLine(
            into: foreign, command: ours, canReplace: { _ in false }
        )
        #expect(!cc)
        #expect(((c["statusLine"] as? [String: Any])?["command"] as? String) == "/opt/other/statusline")
        // Orphan foreign (its executable is gone): we take the slot.
        let (d, cd) = HookConfigurator.installingStatusLine(
            into: foreign, command: ours, canReplace: { _ in true }
        )
        #expect(cd)
        #expect(((d["statusLine"] as? [String: Any])?["command"] as? String) == ours)
    }

    @Test func toolEventsGetWildcardMatcher() {
        let (merged, _) = HookConfigurator.mergingHooks(into: [:])
        let pre = ((merged["hooks"] as? [String: Any])?["PreToolUse"] as? [[String: Any]])?.first
        #expect(pre?["matcher"] as? String == "*")
        let stop = ((merged["hooks"] as? [String: Any])?["Stop"] as? [[String: Any]])?.first
        #expect(stop?["matcher"] == nil)
    }

    @Test func codexMergeInstallsOnlySupportedEventsWithCodexSource() {
        let (merged, changed) = HookConfigurator.mergingCodexHooks(into: [:])
        #expect(changed)
        let hooks = merged["hooks"] as? [String: Any]
        let installedEvents = Set(hooks?.keys.map { $0 } ?? [])
        #expect(installedEvents == Set(HookConfigurator.codexEvents))
        #expect(hooks?["Notification"] == nil)
        #expect(hooks?["StopFailure"] == nil)
        #expect(hooks?["SessionEnd"] == nil)

        #expect(installedEvents == Set([
            "SessionStart", "UserPromptSubmit", "PermissionRequest",
            "PostToolUse", "SubagentStop", "Stop",
        ]))

        let post = (hooks?["PostToolUse"] as? [[String: Any]])?.first
        let command = ((post?["hooks"] as? [[String: Any]])?.first)?["command"] as? String
        #expect(command?.contains("--source codex") == true)
        #expect(post?["matcher"] as? String == "")
        #expect(hooks?["PreToolUse"] == nil)
        #expect(hooks?["PreCompact"] == nil)
        #expect(hooks?["PostCompact"] == nil)
        #expect(hooks?["SubagentStart"] == nil)
    }

    @Test func codexMergePreservesExistingHooksAndIsIdempotent() {
        let vibeCommand = "'/Users/x/.vibe-island/bin/vibe-island-bridge' --source codex"
        let existing: [String: Any] = [
            "custom": ["preserve": true],
            "hooks": [
                "Stop": [[
                    "hooks": [[
                        "type": "command",
                        "command": vibeCommand,
                        "timeout": 5,
                    ]],
                ]],
            ],
        ]
        let (once, changed) = HookConfigurator.mergingCodexHooks(into: existing)
        #expect(changed)
        #expect(((once["custom"] as? [String: Any])?["preserve"] as? Bool) == true)
        let stopGroups = (once["hooks"] as? [String: Any])?["Stop"] as? [[String: Any]]
        #expect(stopGroups?.count == 2)
        let firstCommand = ((stopGroups?[0]["hooks"] as? [[String: Any]])?[0]["command"]) as? String
        #expect(firstCommand == vibeCommand)

        let (twice, changedAgain) = HookConfigurator.mergingCodexHooks(into: once)
        #expect(!changedAgain)
        #expect(HookConfigurator.codexHooksInstalled(in: twice))
    }

    @Test func codexMergeRemovesOnlyObsoleteVedettaEventHandlers() {
        let vedetta = HookConfigurator.bridgeCommand(source: "codex")
        let existing: [String: Any] = [
            "hooks": [
                "PreToolUse": [
                    ["hooks": [["type": "command", "command": "user-pre-tool"]]],
                    ["hooks": [["type": "command", "command": vedetta]]],
                ],
            ],
        ]

        #expect(!HookConfigurator.codexHooksInstalled(in: existing))
        let (merged, changed) = HookConfigurator.mergingCodexHooks(into: existing)
        #expect(changed)
        let hooks = merged["hooks"] as? [String: Any]
        let preGroups = hooks?["PreToolUse"] as? [[String: Any]]
        #expect(preGroups?.count == 1)
        let command = ((preGroups?.first?["hooks"] as? [[String: Any]])?.first)?["command"] as? String
        #expect(command == "user-pre-tool")
        #expect(HookConfigurator.codexHooksInstalled(in: merged))
    }

    @Test func codexRemoveStripsOnlyCodexVedettaHooks() {
        let (merged, _) = HookConfigurator.mergingCodexHooks(into: userSettings())
        #expect(HookConfigurator.hasAnyCodexHook(in: merged))

        let (removed, changed) = HookConfigurator.removingCodexHooks(from: merged)
        #expect(changed)
        #expect(!HookConfigurator.hasAnyCodexHook(in: removed))
        let stopGroups = (removed["hooks"] as? [String: Any])?["Stop"] as? [[String: Any]]
        #expect(stopGroups?.count == 1)
        let command = ((stopGroups?[0]["hooks"] as? [[String: Any]])?[0]["command"]) as? String
        #expect(command?.contains("afplay") == true)
    }

    @Test func codexHooksUseObservedTimeoutsAndMatchers() {
        let (merged, _) = HookConfigurator.mergingCodexHooks(into: [:])
        let hooks = merged["hooks"] as? [String: Any]

        for event in HookConfigurator.codexEvents {
            let group = (hooks?[event] as? [[String: Any]])?.first
            let hook = (group?["hooks"] as? [[String: Any]])?.first
            let expectedTimeout = event == "PermissionRequest" ? 7_200 : 5
            #expect(hook?["timeout"] as? Int == expectedTimeout, "timeout errato per \(event)")
            if event == "PostToolUse" {
                #expect(group?["matcher"] as? String == "")
            } else {
                #expect(group?["matcher"] == nil, "matcher inatteso per \(event)")
            }
        }
    }

    @Test func claudeKeepsItsOwnTimeoutAndMatcherContract() {
        let (merged, _) = HookConfigurator.mergingHooks(into: [:])
        let hooks = merged["hooks"] as? [String: Any]
        let permissionGroup = (hooks?["PermissionRequest"] as? [[String: Any]])?.first
        let permissionHook = (permissionGroup?["hooks"] as? [[String: Any]])?.first
        #expect(permissionHook?["timeout"] as? Int == 86_400)
        #expect(permissionGroup?["matcher"] as? String == "*")

        let postGroup = (hooks?["PostToolUse"] as? [[String: Any]])?.first
        let postHook = (postGroup?["hooks"] as? [[String: Any]])?.first
        #expect(postHook?["timeout"] == nil)
        #expect(postGroup?["matcher"] as? String == "*")
    }
}
