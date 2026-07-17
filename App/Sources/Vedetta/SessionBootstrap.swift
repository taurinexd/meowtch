import Foundation
import VedettaKit

/// Adopts recent sessions from the transcript files at launch, so the
/// panel is populated even for sessions that started before the app did
/// (the original does the same: its list survives restarts).
enum SessionBootstrap {
    /// Transcripts touched within this window are considered current.
    static let recencyWindow: TimeInterval = 24 * 3600
    static let maxSessions = 30
    /// A transcript touched this recently means the session is working.
    static let activeWindow: TimeInterval = 45

    /// Session ids that receive live hook events: the periodic refresh
    /// must not fight the reducer over them.
    @MainActor static var liveEventIds: Set<String> = []
    @MainActor private static var scannedPaths: [String: String] = [:]

    @MainActor
    static func adoptRecentSessions(into store: SessionStore) {
        let projectsDir = NSHomeDirectory() + "/.claude/projects"
        let fm = FileManager.default
        guard let projects = try? fm.contentsOfDirectory(atPath: projectsDir) else { return }

        var candidates: [(path: String, id: String, modified: Date, created: Date)] = []
        let cutoff = Date().addingTimeInterval(-recencyWindow)

        for project in projects {
            let dir = projectsDir + "/" + project
            guard let files = try? fm.contentsOfDirectory(atPath: dir) else { continue }
            for file in files where file.hasSuffix(".jsonl") {
                let path = dir + "/" + file
                guard let attrs = try? fm.attributesOfItem(atPath: path),
                      let modified = attrs[.modificationDate] as? Date,
                      modified > cutoff else { continue }
                let created = attrs[.creationDate] as? Date ?? modified
                candidates.append((path, String(file.dropLast(6)), modified, created))
            }
        }

        for candidate in candidates.sorted(by: { $0.modified > $1.modified }).prefix(maxSessions) {
            guard !store.sessions.contains(where: { $0.id == candidate.id }) else { continue }
            let peek = TranscriptPeek.read(path: candidate.path)
            guard peek.firstUserPrompt != nil || peek.sessionName != nil else { continue }
            scannedPaths[candidate.id] = candidate.path
            FullScanScheduler.schedule(path: candidate.path, sessionId: candidate.id)
            let isActive = candidate.modified.timeIntervalSinceNow > -activeWindow
            store.upsert(AgentSession(
                id: candidate.id,
                agent: .claude,
                title: peek.sessionName ?? peek.firstUserPrompt ?? "",
                directory: peek.cwd ?? "",
                lastMessage: peek.lastUserText,
                lastAssistantMessage: peek.lastAssistantText,
                state: isActive ? .running : .waitingForInput,
                startedAt: candidate.created,
                lastActivityAt: candidate.modified
            ))
        }
    }

    /// Periodic pass for sessions without live hook events (started before
    /// the hooks were installed): transcript mtime drives running/waiting
    /// and the message lines are re-peeked when the file changes.
    @MainActor
    static func refreshScannedSessions(in store: SessionStore) {
        let fm = FileManager.default
        for (id, path) in scannedPaths where !liveEventIds.contains(id) {
            guard var session = store.sessions.first(where: { $0.id == id }),
                  let attrs = try? fm.attributesOfItem(atPath: path),
                  let modified = attrs[.modificationDate] as? Date else { continue }

            let isActive = modified.timeIntervalSinceNow > -activeWindow
            let newState: SessionState = isActive ? .running : .waitingForInput
            let changed = modified > session.lastActivityAt || newState != session.state
            guard changed else { continue }

            let peek = TranscriptPeek.read(path: path)
            if let name = peek.sessionName { session.title = name }
            if let last = peek.lastUserText { session.lastMessage = last }
            if let reply = peek.lastAssistantText { session.lastAssistantMessage = reply }
            session.state = newState
            session.lastActivityAt = modified
            store.upsert(session)
        }
    }
}
