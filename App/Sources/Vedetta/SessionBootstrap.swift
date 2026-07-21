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
    static func registerScannedPath(_ path: String, for id: String) {
        scannedPaths[id] = path
    }

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
            // Real activity is the last message timestamp, not the file
            // mtime (background writes keep the mtime falsely fresh).
            let activity = peek.lastActivity ?? candidate.modified
            let isActive = activity.timeIntervalSinceNow > -activeWindow
            store.upsert(AgentSession(
                id: candidate.id,
                agent: .claude,
                title: peek.sessionName ?? peek.aiTitle ?? peek.firstUserPrompt ?? "",
                directory: peek.cwd ?? "",
                lastMessage: peek.lastUserText,
                lastAssistantMessage: peek.lastAssistantText,
                recap: peek.awaySummary,
                state: isActive ? .running : .waitingForInput,
                startedAt: candidate.created,
                lastActivityAt: activity
            ))
        }
    }

    // MARK: - Codex

    /// Adopts recent Codex CLI sessions from the rollout files, titled via
    /// the session index. No hooks: mtime drives running/waiting.
    @MainActor
    static func adoptCodexSessions(into store: SessionStore) {
        let fm = FileManager.default
        let home = NSHomeDirectory()
        let root = home + "/.codex/sessions"
        guard let enumerator = fm.enumerator(atPath: root) else { return }

        let cutoff = Date().addingTimeInterval(-recencyWindow)
        var names: [String: String] = [:]
        if let indexData = fm.contents(atPath: home + "/.codex/session_index.jsonl") {
            names = CodexScan.parseIndex(indexData)
        }

        while let relative = enumerator.nextObject() as? String {
            guard relative.hasSuffix(".jsonl") else { continue }
            let path = root + "/" + relative
            guard let attrs = try? fm.attributesOfItem(atPath: path),
                  let modified = attrs[.modificationDate] as? Date,
                  modified > cutoff,
                  let data = fm.contents(atPath: path) else { continue }

            let rollout = CodexScan.parseRollout(data)
            guard let id = rollout.sessionId,
                  !store.sessions.contains(where: { $0.id == id }) else { continue }
            let created = attrs[.creationDate] as? Date ?? modified
            scannedPaths[id] = path
            store.upsert(AgentSession(
                id: id,
                agent: .codex,
                title: names[id] ?? rollout.firstUserMessage ?? "",
                directory: rollout.cwd ?? "",
                currentTool: rollout.currentTool,
                currentToolDetail: rollout.currentToolDetail,
                lastMessage: rollout.lastUserMessage,
                lastAssistantMessage: rollout.lastAgentMessage,
                state: rollout.state == .running ? .running : .waitingForInput,
                startedAt: created,
                lastActivityAt: rollout.lastActivityAt ?? modified
            ))
        }
    }

    /// Folds a Codex rollout file into a session's live fields — state (from
    /// task_started/task_complete), current tool (last open function_call), and
    /// the message lines. Returns the updated session, or nil if unreadable.
    /// Shared by the periodic pass and the live FSEvents watcher.
    static func applyCodexRollout(to session: AgentSession, path: String) -> AgentSession? {
        guard let data = FileManager.default.contents(atPath: path) else { return nil }
        let rollout = CodexScan.parseRollout(data)
        var updated = session
        if let last = rollout.lastUserMessage { updated.lastMessage = last }
        if let reply = rollout.lastAgentMessage { updated.lastAssistantMessage = reply }
        updated.currentTool = rollout.currentTool
        updated.currentToolDetail = rollout.currentToolDetail
        updated.state = rollout.state == .running ? .running : .waitingForInput
        if let activity = rollout.lastActivityAt { updated.lastActivityAt = activity }
        return updated
    }

    /// Adopts or updates the Codex session a rollout belongs to (the live
    /// watcher's entry point for a changed file, incl. brand-new sessions).
    @MainActor
    static func ingestCodexRollout(path: String, into store: SessionStore) {
        guard let data = FileManager.default.contents(atPath: path) else { return }
        let rollout = CodexScan.parseRollout(data)
        guard let id = rollout.sessionId else { return }
        scannedPaths[id] = path
        let existing = store.sessions.first { $0.id == id }
        let base = existing ?? AgentSession(
            id: id,
            agent: .codex,
            title: rollout.firstUserMessage ?? "",
            directory: rollout.cwd ?? "",
            state: .waitingForInput,
            startedAt: Date(),
            lastActivityAt: Date()
        )
        if let updated = applyCodexRollout(to: base, path: path) {
            store.upsert(updated)
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

            // Codex has no hooks: its rollout drives state, tool and messages
            // directly (event-based, not mtime), so route it through the same
            // path the live watcher uses.
            if session.agent == .codex {
                if let updated = applyCodexRollout(to: session, path: path) {
                    store.upsert(updated)
                }
                continue
            }

            var activity = modified
            let peek = TranscriptPeek.read(path: path)
            if let name = peek.sessionName ?? peek.aiTitle { session.title = name }
            if let last = peek.lastUserText { session.lastMessage = last }
            if let reply = peek.lastAssistantText { session.lastAssistantMessage = reply }
            if let real = peek.lastActivity { activity = real }
            // Unconditional: nil means the recap is stale or absent.
            session.recap = peek.awaySummary
            session.state = activity.timeIntervalSinceNow > -activeWindow ? .running : .waitingForInput
            session.lastActivityAt = activity
            store.upsert(session)
        }

        // Live sessions get state and messages from hook events, but the
        // recap is written out-of-band minutes AFTER Stop (while the user
        // is away): re-peek just that, touching nothing the events own.
        for (id, path) in scannedPaths where liveEventIds.contains(id) {
            guard var session = store.sessions.first(where: { $0.id == id }),
                  session.agent == .claude else { continue }
            let recap = TranscriptPeek.read(path: path).awaySummary
            if session.recap != recap {
                session.recap = recap
                store.upsert(session)
            }
        }
    }
}
