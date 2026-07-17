import Foundation
import Combine

/// Observable source of truth for the sessions shown in the panel.
/// Kept sorted: approvals first, then waiting, running, completed;
/// ties broken by most recent activity.
@MainActor
public final class SessionStore: ObservableObject {
    @Published public private(set) var sessions: [AgentSession] = []

    public init() {}

    public func upsert(_ session: AgentSession) {
        if let index = sessions.firstIndex(where: { $0.id == session.id }) {
            sessions[index] = session
        } else {
            sessions.append(session)
        }
        sort()
    }

    public func transition(id: String, to state: SessionState, at date: Date = Date()) {
        guard let index = sessions.firstIndex(where: { $0.id == id }) else { return }
        sessions[index].state = state
        sessions[index].lastActivityAt = date
        sort()
    }

    public func remove(id: String) {
        sessions.removeAll { $0.id == id }
    }

    private func sort() {
        sessions.sort {
            if $0.state != $1.state { return $0.state < $1.state }
            return $0.lastActivityAt > $1.lastActivityAt
        }
    }
}
