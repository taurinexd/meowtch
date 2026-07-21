import Foundation
import VedettaKit

/// While Vibe Island is installed its persisted map contributes set parity,
/// custom titles and the window mapping for the sessions it knows — but the
/// map freezes the moment VI quits, so it only complements (never replaces)
/// Vedetta's own transcript sweep.
@MainActor
enum VIMapImport {
    static var mapPath: String {
        NSHomeDirectory() + "/Library/Application Support/vibe-island/session-terminals.json"
    }

    /// Returns true when the map was found and imported.
    static func adopt(into store: SessionStore) -> Bool {
        guard let data = FileManager.default.contents(atPath: mapPath),
              let object = try? JSONSerialization.jsonObject(with: data),
              let map = object as? [String: [String: Any]], !map.isEmpty else { return false }

        for (id, info) in map {
            guard !store.sessions.contains(where: { $0.id == id }) else { continue }

            let state: SessionState
            switch info["status"] as? String {
            case "processing", "running_tool": state = .running
            case "compacting": state = .compacting
            default: state = .waitingForInput
            }

            // lastActivityAt is a Mac reference-date epoch.
            let activity = (info["lastActivityAt"] as? NSNumber)
                .map { Date(timeIntervalSinceReferenceDate: $0.doubleValue) } ?? Date()

            let title = (info["customTitle"] as? String)
                ?? (info["firstUserMessage"] as? String) ?? ""

            store.upsert(AgentSession(
                id: id,
                agent: (info["source"] as? String) == "codex" ? .codex : .claude,
                title: title,
                directory: info["cwd"] as? String ?? "",
                currentTool: state == .running ? info["currentTool"] as? String : nil,
                currentToolDetail: state == .running ? info["toolTarget"] as? String : nil,
                lastMessage: info["lastUserMessage"] as? String,
                lastAssistantMessage: (info["lastAssistantMessageFull"] as? String)
                    ?? (info["lastAssistantMessage"] as? String),
                state: state,
                startedAt: activity,
                lastActivityAt: activity
            ))

            if let bundle = info["bundleIdentifier"] as? String {
                store.setTerminal(TerminalInfo(
                    tty: info["tty"] as? String,
                    termProgram: info["termProgram"] as? String,
                    bundleIdentifier: bundle
                ), for: id)
            }

            if let path = transcriptPath(for: id) {
                SessionBootstrap.registerScannedPath(path, for: id)
                FullScanScheduler.schedule(path: path, sessionId: id)
            }
        }
        return true
    }

    /// Finds the transcript for a session id across the project dirs.
    private static func transcriptPath(for id: String) -> String? {
        let projectsDir = NSHomeDirectory() + "/.claude/projects"
        let fm = FileManager.default
        guard let projects = try? fm.contentsOfDirectory(atPath: projectsDir) else { return nil }
        for project in projects {
            let candidate = projectsDir + "/" + project + "/" + id + ".jsonl"
            if fm.fileExists(atPath: candidate) { return candidate }
        }
        return nil
    }
}
