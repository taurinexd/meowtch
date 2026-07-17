import Foundation

/// Identity of the terminal that hosts a session, captured by the bridge
/// at hook time (the hook runs inside the terminal's process context).
public struct TerminalInfo: Codable, Sendable, Equatable {
    public var tty: String?
    public var termProgram: String?
    public var bundleIdentifier: String?
    public var pid: Int32?

    public init(
        tty: String? = nil,
        termProgram: String? = nil,
        bundleIdentifier: String? = nil,
        pid: Int32? = nil
    ) {
        self.tty = tty
        self.termProgram = termProgram
        self.bundleIdentifier = bundleIdentifier
        self.pid = pid
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
            store.setTerminal(TerminalInfo(
                tty: terminal["tty"] as? String,
                termProgram: terminal["termProgram"] as? String,
                bundleIdentifier: terminal["bundleIdentifier"] as? String,
                pid: (terminal["pid"] as? NSNumber)?.int32Value
            ), for: sessionId)
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
        if let cwd { session.directory = cwd }
        session.lastActivityAt = date

        switch name {
        case "SessionStart":
            session.state = .running

        case "UserPromptSubmit":
            session.state = .running
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
            session.currentToolDetail = toolDetail(from: event["tool_input"] as? [String: Any])

        case "PostToolUse":
            session.currentTool = nil
            session.currentToolDetail = nil

        case "Stop", "StopFailure":
            session.state = .waitingForInput
            session.currentTool = nil
            session.currentToolDetail = nil
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
        if let name = peek.sessionName {
            session.title = name
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

    /// Compact one-line description of what the tool is touching,
    /// mirroring the original's tool row (command, file name, …).
    private static func toolDetail(from input: [String: Any]?) -> String? {
        guard let input else { return nil }
        if let command = input["command"] as? String { return command }
        if let path = input["file_path"] as? String {
            return (path as NSString).lastPathComponent
        }
        if let pattern = input["pattern"] as? String { return pattern }
        if let url = input["url"] as? String { return url }
        if let description = input["description"] as? String { return description }
        return nil
    }
}
