public enum SessionRefreshPolicy {
    public static func shouldApplyStateHeuristic(
        agent: AgentKind,
        hasLiveHook: Bool
    ) -> Bool {
        agent == .codex || !hasLiveHook
    }
}
