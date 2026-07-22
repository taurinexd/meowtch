import Foundation

/// Decides when a session's card must leave the panel because its terminal
/// is provably dead (the original keeps tty + pids per session in its terminal map and
/// its cards follow the terminal's life). Everything here errs toward
/// keeping: a card is removed only on positive evidence of death.
public enum SessionLivenessPolicy {
    /// A dead Codex writer only counts once the rollout has been quiet for
    /// this long: a resumed thread swaps writers and must get the chance to
    /// rebind before the card disappears.
    public static let fallbackGrace: TimeInterval = 60

    public static func shouldRemove(
        session: AgentSession,
        terminal: TerminalInfo?,
        isPidAttachedToTTY: (Int, String) -> Bool,
        isProcessAlive: (Int) -> Bool,
        now: Date = Date()
    ) -> Bool {
        guard let terminal else { return false }

        if terminal.isWriterFallback == true {
            // Rollout-fallback identity: the writer process stands in for
            // the terminal. Only a writer that died AND stayed quiet counts —
            // the live rollout path re-runs the writer lookup on new events.
            guard let pid = terminal.pid else { return false }
            return !isProcessAlive(Int(pid))
                && now.timeIntervalSince(session.lastActivityAt) > fallbackGrace
        }

        // Hook-captured identity. chain[0] is the bridge itself and chain[1]
        // its sh wrapper, both dead by design the moment the hook returns;
        // the session lives through chain[2] (the agent) and chain[3] (the
        // shell hosting it).
        if let tty = terminal.tty {
            // A merely-ended session keeps its shell on the tty and stays; a
            // killed terminal tab loses every ancestor. A recycled tty name
            // hosts foreign pids, so it reads as dead for THIS chain.
            guard let chain = terminal.pidChain, chain.count > 1 else { return false }
            return !chain.dropFirst().contains { isPidAttachedToTTY($0, tty) }
        }

        // Hooks usually run with plain pipes and capture no tty. The shell
        // is then the terminal's stand-in: the agent alone dying is a normal
        // session end with the tab still open, so removal requires the whole
        // agent+shell segment to be gone.
        guard let chain = terminal.pidChain, chain.count >= 3 else { return false }
        let segment = [chain[2], chain.count >= 4 ? chain[3] : nil].compactMap { $0 }
        return !segment.contains(where: isProcessAlive)
    }
}
