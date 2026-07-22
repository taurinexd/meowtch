import Foundation
import VedettaKit

/// Runs TranscriptFullScan off the main actor, throttled per session, and
/// applies the results (user-given name, task list) to the store. Static
/// and capture-free so results cross actors as Sendable values only.
@MainActor
enum FullScanScheduler {
    private static var lastScan: [String: Date] = [:]
    /// Minimum interval between scans of the same session.
    private static let throttle: TimeInterval = 45

    static func schedule(path: String, sessionId: String) {
        let now = Date()
        if let last = lastScan[sessionId], now.timeIntervalSince(last) < throttle { return }
        lastScan[sessionId] = now

        let runStartedAt = SessionRunRegistry.runStart(for: sessionId)
        Task.detached(priority: .utility) {
            let result = TranscriptFullScan.run(path: path)
            // The live task files are authoritative; the transcript rebuild
            // is only a fallback for sessions with no task directory (it
            // can resurrect tasks cleared before a compaction). Files last
            // touched before the current run are a closed run's leftovers:
            // show nothing rather than a list the session no longer has.
            let tasks: SessionTasks?
            if SessionTasks.isAbandoned(
                latestModification: SessionTasks.latestModification(sessionId: sessionId),
                runStartedAt: runStartedAt
            ) {
                tasks = SessionTasks(items: [])
            } else {
                tasks = SessionTasks.load(sessionId: sessionId) ?? result.tasks
            }
            await apply(result, tasks: tasks, to: sessionId)
        }
    }

    /// Re-reads just the task files, immediately (no throttle): called when
    /// a Task* tool runs so the widget tracks the agent's list live.
    static func reloadTasks(sessionId: String) {
        Task.detached(priority: .utility) {
            guard let tasks = SessionTasks.load(sessionId: sessionId) else { return }
            await apply(nil, tasks: tasks, to: sessionId)
        }
    }

    private static func apply(
        _ result: TranscriptFullScan.Result?,
        tasks: SessionTasks?,
        to sessionId: String
    ) {
        guard let store = EventDispatcher.store,
              var session = store.sessions.first(where: { $0.id == sessionId }) else { return }
        var changed = false
        let bestTitle = result.flatMap { $0.sessionName ?? $0.aiTitle }
        if let bestTitle, session.title != bestTitle {
            session.title = bestTitle
            changed = true
        }
        if let tasks, session.tasks != tasks {
            session.tasks = tasks
            changed = true
        }
        if changed { store.upsert(session) }
    }
}
