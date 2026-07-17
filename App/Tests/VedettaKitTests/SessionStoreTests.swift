import Testing
import Foundation
@testable import VedettaKit

@MainActor
struct SessionStoreTests {

    private func makeSession(
        id: String,
        state: SessionState,
        lastActivityAt: Date = Date(timeIntervalSince1970: 1_000)
    ) -> AgentSession {
        AgentSession(
            id: id,
            agent: .claude,
            title: "test session \(id)",
            directory: "/tmp/\(id)",
            state: state,
            startedAt: Date(timeIntervalSince1970: 0),
            lastActivityAt: lastActivityAt
        )
    }

    @Test func upsertInsertsNewSession() {
        let store = SessionStore()
        store.upsert(makeSession(id: "a", state: .running))
        #expect(store.sessions.count == 1)
        #expect(store.sessions.first?.id == "a")
    }

    @Test func upsertUpdatesExistingSessionById() {
        let store = SessionStore()
        store.upsert(makeSession(id: "a", state: .running))
        var updated = makeSession(id: "a", state: .completed)
        updated.title = "renamed"
        store.upsert(updated)
        #expect(store.sessions.count == 1)
        #expect(store.sessions.first?.state == .completed)
        #expect(store.sessions.first?.title == "renamed")
    }

    @Test func sortingPutsApprovalsFirstThenWaitingThenRunningThenCompleted() {
        let store = SessionStore()
        store.upsert(makeSession(id: "done", state: .completed))
        store.upsert(makeSession(id: "run", state: .running))
        store.upsert(makeSession(id: "appr", state: .needsApproval))
        store.upsert(makeSession(id: "wait", state: .waitingForInput))
        #expect(store.sessions.map(\.id) == ["appr", "wait", "run", "done"])
    }

    @Test func sortingBreaksTiesByMostRecentActivity() {
        let store = SessionStore()
        store.upsert(makeSession(id: "old", state: .running,
                                 lastActivityAt: Date(timeIntervalSince1970: 100)))
        store.upsert(makeSession(id: "new", state: .running,
                                 lastActivityAt: Date(timeIntervalSince1970: 200)))
        #expect(store.sessions.map(\.id) == ["new", "old"])
    }

    @Test func transitionChangesStateAndBumpsActivity() {
        let store = SessionStore()
        store.upsert(makeSession(id: "a", state: .running,
                                 lastActivityAt: Date(timeIntervalSince1970: 100)))
        let now = Date(timeIntervalSince1970: 500)
        store.transition(id: "a", to: .needsApproval, at: now)
        #expect(store.sessions.first?.state == .needsApproval)
        #expect(store.sessions.first?.lastActivityAt == now)
    }

    @Test func transitionUnknownIdIsIgnored() {
        let store = SessionStore()
        store.upsert(makeSession(id: "a", state: .running))
        store.transition(id: "ghost", to: .completed, at: Date())
        #expect(store.sessions.count == 1)
        #expect(store.sessions.first?.state == .running)
    }

    @Test func minimizedSessionsSortLastRegardlessOfState() {
        let store = SessionStore()
        var minimized = makeSession(id: "min-appr", state: .needsApproval)
        minimized.isMinimized = true
        store.upsert(minimized)
        store.upsert(makeSession(id: "done", state: .completed))
        store.upsert(makeSession(id: "run", state: .running))
        #expect(store.sessions.map(\.id) == ["run", "done", "min-appr"])
    }

    @Test func removeClearsSession() {
        let store = SessionStore()
        store.upsert(makeSession(id: "a", state: .completed))
        store.remove(id: "a")
        #expect(store.sessions.isEmpty)
    }
}
