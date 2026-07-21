import Foundation

/// Identity of the terminal that hosts a session, captured by the bridge
/// at hook time (the hook runs inside the terminal's process context).
public struct TerminalInfo: Codable, Sendable, Equatable {
    public var tty: String?
    public var termProgram: String?
    public var bundleIdentifier: String?
    public var pid: Int32?
    /// CGWindowID of the window hosting the session, captured by the
    /// bridge at hook time — the jump raises exactly this window.
    public var windowId: Int?
    /// The bridge's process ancestry at hook time. The bridge itself is
    /// gone by jump time, but the chain includes the terminal's live
    /// shell — what the VS Code extension matches terminals against.
    public var pidChain: [Int]?

    public init(
        tty: String? = nil,
        termProgram: String? = nil,
        bundleIdentifier: String? = nil,
        pid: Int32? = nil,
        windowId: Int? = nil,
        pidChain: [Int]? = nil
    ) {
        self.tty = tty
        self.termProgram = termProgram
        self.bundleIdentifier = bundleIdentifier
        self.pid = pid
        self.windowId = windowId
        self.pidChain = pidChain
    }
}

/// Turns bridge envelopes (hook payload + terminal identity) into
/// SessionStore mutations. Pure w.r.t. inputs: all context lives in the
/// store, so events for sessions the app never saw create them lazily
/// (the app may start after the session did).
@MainActor
public enum SessionEventReducer {

    public static func apply(
        _ envelope: [String: Any],
        to store: SessionStore,
        at date: Date = Date()
    ) {
        guard let event = envelope["event"] as? [String: Any],
              let name = event["hook_event_name"] as? String,
              let sessionId = event["session_id"] as? String else { return }

        let source = envelope["source"] as? String ?? "claude"
        let cwd = event["cwd"] as? String

        if let terminal = envelope["terminal"] as? [String: Any] {
            var info = TerminalInfo(
                tty: terminal["tty"] as? String,
                termProgram: terminal["termProgram"] as? String,
                bundleIdentifier: terminal["bundleIdentifier"] as? String,
                pid: (terminal["pid"] as? NSNumber)?.int32Value,
                windowId: (terminal["windowId"] as? NSNumber)?.intValue,
                pidChain: (terminal["pidChain"] as? [Any])?
                    .compactMap { ($0 as? NSNumber)?.intValue }
            )
            // The window binding is trustworthy only when the user is
            // certainly typing in it: background events (the agent works
            // while the user is in another window of the same app) must
            // not rebind the session to whatever window is frontmost.
            let userDriven = name == "UserPromptSubmit" || name == "SessionStart"
            if !userDriven, let previous = store.terminal(for: sessionId)?.windowId {
                info.windowId = previous
            }
            store.setTerminal(info, for: sessionId)
        }

        var session = store.sessions.first { $0.id == sessionId }
            ?? AgentSession(
                id: sessionId,
                agent: AgentKind(rawValue: source) ?? .claude,
                title: "",
                directory: cwd ?? "",
                state: .running,
                startedAt: date,
                lastActivityAt: date
            )
        // The card shows the project root (VS Code's open folder), like the
        // original — not wherever the agent cd'd to. A cwd that is a
        // subdirectory of the one we have must not replace it; a shallower
        // or unrelated cwd (a real project switch) does.
        if let cwd { session.directory = rootDirectory(current: session.directory, cwd: cwd) }
        if let model = event["model"] as? String, !model.isEmpty {
            session.model = model
        }
        if source == "codex" {
            session.codexThreadID = event["codex_thread_id"] as? String
            session.currentTurnID = (event["codex_turn_id"] as? String)
                ?? (event["turn_id"] as? String)
            session.currentToolUseID = event["tool_use_id"] as? String
            session.permissionMode = event["permission_mode"] as? String
        }
        session.lastActivityAt = date

        switch name {
        case "SessionStart":
            // After a compaction the session resumes: a manual /compact
            // leaves it waiting for the user, an auto-compact happens
            // mid-turn so the agent keeps working.
            if session.state == .compacting {
                session.state = session.compactTrigger == "auto" ? .running : .waitingForInput
                session.compactingStartedAt = nil
                session.compactTrigger = nil
            } else {
                session.state = .running
            }

        case "PreCompact":
            session.state = .compacting
            session.compactingStartedAt = date
            session.compactTrigger = event["trigger"] as? String
            session.currentTool = nil
            session.currentToolDetail = nil

        case "UserPromptSubmit":
            session.state = .running
            // A new prompt starts a new turn: the previous recap is stale.
            session.recap = nil
            if let prompt = event["prompt"] as? String, !prompt.isEmpty,
               !prompt.hasPrefix("<") {
                session.lastMessage = prompt
                // Slash commands make poor titles; a user-given session
                // name (from enrich) always has priority anyway.
                if session.title.isEmpty && !prompt.hasPrefix("/") {
                    session.title = prompt
                }
            }

        case "PreToolUse":
            session.state = .running
            session.currentTool = event["tool_name"] as? String
            session.currentToolDetail = toolDetail(from: event["tool_input"])

        case "PostToolUse":
            // Keep the last tool shown between calls, like the original —
            // it's cleared only when the turn ends (Stop).
            break

        case "Stop", "StopFailure":
            session.state = .waitingForInput
            session.currentTool = nil
            session.currentToolDetail = nil
            session.compactingStartedAt = nil
            session.compactTrigger = nil
            if let reply = event["last_assistant_message"] as? String, !reply.isEmpty {
                session.lastAssistantMessage = reply
            }
            enrich(from: event, into: &session)
            // The final assistant message may not have hit the transcript
            // yet when Stop fires: re-read shortly after.
            scheduleReplyRefresh(for: sessionId, from: event, in: store)

        case "SessionEnd":
            session.state = .completed
            session.currentTool = nil
            session.currentToolDetail = nil
            enrich(from: event, into: &session)

        case "SubagentStart":
            session.subagentCount += 1

        case "SubagentStop":
            session.subagentCount = max(0, session.subagentCount - 1)

        case "Notification":
            let message = (event["message"] as? String)?.lowercased() ?? ""
            if message.contains("permission") {
                session.state = .needsApproval
            } else if message.contains("waiting") {
                session.state = .waitingForInput
            }

        default:
            break
        }

        // Sessions adopted mid-flight (the app started after them) have no
        // title yet: backfill it from the transcript.
        if session.title.isEmpty || session.lastMessage == nil {
            enrich(from: event, into: &session)
        }

        store.upsert(session)
    }

    private static func scheduleReplyRefresh(
        for sessionId: String,
        from event: [String: Any],
        in store: SessionStore
    ) {
        guard let path = event["transcript_path"] as? String else { return }
        Task { @MainActor in
            for delay in [700, 2_000] {
                try? await Task.sleep(for: .milliseconds(delay))
                guard var session = store.sessions.first(where: { $0.id == sessionId }) else { return }
                let peek = TranscriptPeek.read(path: path)
                if let reply = peek.lastAssistantText, reply != session.lastAssistantMessage {
                    session.lastAssistantMessage = reply
                    if session.title.isEmpty, let first = peek.firstUserPrompt {
                        session.title = first
                    }
                    store.upsert(session)
                    return
                }
            }
        }
    }

    /// Fills title and message lines from the transcript the hook points at.
    /// A name the user gave the session always wins over the prompt fallback.
    private static func enrich(from event: [String: Any], into session: inout AgentSession) {
        guard let path = event["transcript_path"] as? String else { return }
        let peek = TranscriptPeek.read(path: path)
        if let reply = peek.lastAssistantText {
            session.lastAssistantMessage = reply
        }
        // Unconditional: the transcript is the truth for recap presence.
        session.recap = peek.awaySummary
        // Title priority mirrors the original: a name the user gave the
        // session wins, then Claude's auto-generated title, then the first
        // prompt as a last resort.
        if let name = peek.sessionName {
            session.title = name
        } else if let aiTitle = peek.aiTitle {
            session.title = aiTitle
        } else if session.title.isEmpty, let first = peek.firstUserPrompt {
            session.title = first
        }
        if session.lastMessage == nil, let lastUser = peek.lastUserText {
            session.lastMessage = lastUser
        }
        if !session.directory.isEmpty {
            session.gitBranch = GitIdentity.branch(forDirectory: session.directory)
        }
    }

    /// Keeps the shallower of two paths when one contains the other (the
    /// project root survives a `cd` into a subfolder); an unrelated path
    /// wins (the session moved to a different project).
    private static func rootDirectory(current: String, cwd: String) -> String {
        guard !current.isEmpty else { return cwd }
        if cwd == current { return current }
        if cwd.hasPrefix(current + "/") { return current }   // cwd is deeper
        if current.hasPrefix(cwd + "/") { return cwd }        // cwd is shallower
        return cwd
    }

    /// Compact one-line description of what the tool is touching,
    /// mirroring the original's tool row (command, file name, …).
    private static func toolDetail(from value: Any?) -> String? {
        if let text = value as? String, !text.isEmpty { return text }
        guard let input = value as? [String: Any] else { return nil }
        if let command = input["command"] as? String { return command }
        if let command = input["cmd"] as? String { return command }
        if let path = input["file_path"] as? String {
            return (path as NSString).lastPathComponent
        }
        if let path = input["path"] as? String {
            return (path as NSString).lastPathComponent
        }
        if let pattern = input["pattern"] as? String { return pattern }
        if let query = input["query"] as? String { return query }
        if let url = input["url"] as? String { return url }
        if let description = input["description"] as? String { return description }
        return nil
    }
}
