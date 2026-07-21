import Foundation

/// Decides when a session's card must leave the panel because its terminal
/// is provably dead (VI keeps tty + pids per session in its terminal map and
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

        if let tty = terminal.tty {
            // Hook-captured identity. chain[0] is the bridge itself, dead by
            // design the moment the hook returns; the session lives through
            // the other ancestors (shell, agent) still attached to its tty.
            // A merely-ended session keeps its shell on the tty and stays; a
            // killed terminal tab loses them all. A recycled tty name hosts
            // foreign pids, so it reads as dead for THIS session's chain.
            guard let chain = terminal.pidChain, chain.count > 1 else { return false }
            return !chain.dropFirst().contains { isPidAttachedToTTY($0, tty) }
        }

        // Rollout-fallback identity (no tty): the writer process stands in
        // for the terminal. Only a writer that died AND stayed quiet counts —
        // the live rollout path re-runs the writer lookup on new events.
        if let pid = terminal.pid {
            return !isProcessAlive(Int(pid))
                && now.timeIntervalSince(session.lastActivityAt) > fallbackGrace
        }
        return false
    }
}
