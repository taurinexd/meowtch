import Testing
@testable import VedettaKit

struct CodexHomeTests {
    @Test func keepsDefaultCanonicalizesCustomHomesAndDeduplicates() {
        let homes = CodexHomeRegistry.resolve(
            defaultPath: "/Users/x/.codex",
            customPaths: [
                "/Users/x/.codex/",
                "/Users/x/work/../work/codex-a",
                "/Users/x/work/codex-a",
            ],
            directoryExists: { _ in true }
        )

        #expect(homes.map(\.path) == [
            "/Users/x/.codex",
            "/Users/x/work/codex-a",
        ])
        #expect(homes.first?.isDefault == true)
        #expect(homes.last?.isDefault == false)
    }

    @Test func retainsUnavailableCustomHomeForExplicitStatus() {
        let homes = CodexHomeRegistry.resolve(
            defaultPath: "/Users/x/.codex",
            customPaths: ["/Volumes/team/codex"],
            directoryExists: { $0 != "/Volumes/team/codex" }
        )

        #expect(homes.count == 2)
        #expect(homes[1].isAvailable == false)
        #expect(homes[1].hooksPath == "/Volumes/team/codex/hooks.json")
        #expect(homes[1].sessionIndexPath == "/Volumes/team/codex/session_index.jsonl")
        #expect(homes[1].sessionsPath == "/Volumes/team/codex/sessions")
    }

    @Test func detectsOnlyExplicitHooksFeatureDisable() {
        #expect(CodexFeatureConfig.hooksExplicitlyDisabled(in: """
        model = "gpt-5"
        [features]
        hooks = false
        """))
        #expect(!CodexFeatureConfig.hooksExplicitlyDisabled(in: """
        hooks = { state = { stop = { trusted_hash = "abc" } } }
        [features]
        hooks = true
        """))
        #expect(!CodexFeatureConfig.hooksExplicitlyDisabled(in: "# hooks = false"))
    }
}
