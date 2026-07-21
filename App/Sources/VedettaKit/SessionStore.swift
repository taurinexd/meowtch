import Foundation
import Combine

/// Observable source of truth for the sessions shown in the panel.
/// Kept sorted: approvals first, then running, waiting, completed;
/// same-state ties broken by when the state was entered (stable while
/// a card merely stays busy).
@MainActor
public final class SessionStore: ObservableObject {
    @Published public private(set) var sessions: [AgentSession] = []
    /// Terminal identity per session id, captured by the bridge (used by
    /// the jump feature; persisted in M5).
    @Published public private(set) var terminals: [String: TerminalInfo] = [:]

    public init() {}

    public func setTerminal(_ info: TerminalInfo, for id: String) {
        terminals[id] = info
    }

    public func terminal(for id: String) -> TerminalInfo? {
        terminals[id]
    }

    /// Forces observers to re-render time-dependent derivations (row
    /// partitioning by recency) even when no session changed.
    public func touch() {
        objectWillChange.send()
    }

    public func upsert(_ session: AgentSession) {
        var incoming = session
        if let index = sessions.firstIndex(where: { $0.id == session.id }) {
            // stateChangedAt is stamped here, centrally, so every writer
            // (reducer, coordinator, bootstrap) gets it for free.
            if sessions[index].state == incoming.state {
                incoming.stateChangedAt = sessions[index].stateChangedAt
            } else {
                incoming.stateChangedAt = incoming.lastActivityAt
            }
            sessions[index] = incoming
        } else {
            sessions.append(incoming)
        }
        sort()
    }

    public func transition(id: String, to state: SessionState, at date: Date = Date()) {
        guard let index = sessions.firstIndex(where: { $0.id == id }) else { return }
        if sessions[index].state != state {
            sessions[index].stateChangedAt = date
        }
        sessions[index].state = state
        sessions[index].lastActivityAt = date
        sort()
    }

    /// Clears a pending-approval state once its request resolved (decision,
    /// handoff, or abandonment). Only the approval state is cleared: a state
    /// the lifecycle already moved past (Stop → waiting) must not be
    /// clobbered by the resuming continuation.
    public func clearApprovalState(id: String, at date: Date = Date()) {
        guard sessions.first(where: { $0.id == id })?.state == .needsApproval else { return }
        transition(id: id, to: .running, at: date)
    }

    public func remove(id: String) {
        sessions.removeAll { $0.id == id }
        terminals.removeValue(forKey: id)
    }

    private func sort() {
        sessions.sort {
            if $0.isMinimized != $1.isMinimized { return !$0.isMinimized }
            if $0.state != $1.state { return $0.state < $1.state }
            // Same-state ties break on when the state was ENTERED, not on
            // raw activity: per-hook bumps would shuffle running cards.
            if $0.stateChangedAt != $1.stateChangedAt {
                return $0.stateChangedAt > $1.stateChangedAt
            }
            return $0.lastActivityAt > $1.lastActivityAt
        }
    }
}
