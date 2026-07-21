import Testing
@testable import VedettaKit

struct SessionRefreshPolicyTests {
    @Test func stateHeuristicNeverOverridesLiveClaudeLifecycle() {
        #expect(!SessionRefreshPolicy.shouldApplyStateHeuristic(
            agent: .claude,
            hasLiveHook: true
        ))
        #expect(SessionRefreshPolicy.shouldApplyStateHeuristic(
            agent: .claude,
            hasLiveHook: false
        ))
        #expect(SessionRefreshPolicy.shouldApplyStateHeuristic(
            agent: .codex,
            hasLiveHook: true
        ))
    }
}
