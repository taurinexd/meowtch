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

    @Test func toolEventsGetWildcardMatcher() {
        let (merged, _) = HookConfigurator.mergingHooks(into: [:])
        let pre = ((merged["hooks"] as? [String: Any])?["PreToolUse"] as? [[String: Any]])?.first
        #expect(pre?["matcher"] as? String == "*")
        let stop = ((merged["hooks"] as? [String: Any])?["Stop"] as? [[String: Any]])?.first
        #expect(stop?["matcher"] == nil)
    }
}
