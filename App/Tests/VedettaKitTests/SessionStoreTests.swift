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

    @Test func sortingPutsApprovalsFirstThenRunningThenWaitingThenCompleted() {
        let store = SessionStore()
        store.upsert(makeSession(id: "done", state: .completed))
        store.upsert(makeSession(id: "wait", state: .waitingForInput))
        store.upsert(makeSession(id: "appr", state: .needsApproval))
        store.upsert(makeSession(id: "run", state: .running))
        // Working (blue) ranks above waiting (green), like the original.
        #expect(store.sessions.map(\.id) == ["appr", "run", "wait", "done"])
    }

    @Test func sortingBreaksTiesByMostRecentActivity() {
        let store = SessionStore()
        store.upsert(makeSession(id: "old", state: .running,
                                 lastActivityAt: Date(timeIntervalSince1970: 100)))
        store.upsert(makeSession(id: "new", state: .running,
                                 lastActivityAt: Date(timeIntervalSince1970: 200)))
        #expect(store.sessions.map(\.id) == ["new", "old"])
    }

    @Test func activityBumpsDoNotReorderSameStateCards() {
        let store = SessionStore()
        var first = makeSession(id: "first", state: .running,
                                lastActivityAt: Date(timeIntervalSince1970: 100))
        first.stateChangedAt = Date(timeIntervalSince1970: 100)
        var second = makeSession(id: "second", state: .running,
                                 lastActivityAt: Date(timeIntervalSince1970: 200))
        second.stateChangedAt = Date(timeIntervalSince1970: 200)
        store.upsert(first)
        store.upsert(second)
        #expect(store.sessions.map(\.id) == ["second", "first"])

        // A hook bump on the older card must not leapfrog it: same-state
        // order follows when the state was entered, not raw activity.
        var bumped = store.sessions.first { $0.id == "first" }!
        bumped.lastActivityAt = Date(timeIntervalSince1970: 300)
        store.upsert(bumped)
        #expect(store.sessions.map(\.id) == ["second", "first"])
    }

    @Test func stateChangeRestampsStateChangedAtViaUpsert() {
        let store = SessionStore()
        store.upsert(makeSession(id: "a", state: .running,
                                 lastActivityAt: Date(timeIntervalSince1970: 100)))
        var finished = store.sessions[0]
        finished.state = .waitingForInput
        finished.lastActivityAt = Date(timeIntervalSince1970: 500)
        store.upsert(finished)
        #expect(store.sessions.first?.stateChangedAt == Date(timeIntervalSince1970: 500))

        // Same-state updates keep the original stamp.
        var bumped = store.sessions[0]
        bumped.lastActivityAt = Date(timeIntervalSince1970: 900)
        store.upsert(bumped)
        #expect(store.sessions.first?.stateChangedAt == Date(timeIntervalSince1970: 500))
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

    @Test func clearApprovalStateResetsAPendingApprovalToRunning() {
        let store = SessionStore()
        store.upsert(makeSession(id: "a", state: .needsApproval))
        store.clearApprovalState(id: "a", at: Date(timeIntervalSince1970: 2_000))
        #expect(store.sessions.first?.state == .running)
    }

    @Test func clearApprovalStateNeverClobbersAStateTheLifecycleMovedPast() {
        let store = SessionStore()
        store.upsert(makeSession(id: "a", state: .waitingForInput))
        store.clearApprovalState(id: "a", at: Date(timeIntervalSince1970: 2_000))
        // Stop already put the session in waiting: the resuming handoff
        // continuation must not flip it back to running.
        #expect(store.sessions.first?.state == .waitingForInput)
        #expect(store.sessions.first?.lastActivityAt == Date(timeIntervalSince1970: 1_000))
    }

    @Test func removeClearsSessionAndTerminalBinding() {
        let store = SessionStore()
        store.upsert(makeSession(id: "a", state: .completed))
        store.setTerminal(TerminalInfo(tty: "/dev/ttys001"), for: "a")
        store.remove(id: "a")
        #expect(store.sessions.isEmpty)
        #expect(store.terminal(for: "a") == nil)
    }
}
