import Foundation

/// Sole state writer for Codex sessions. Each ingress source is allowed to
/// update only its observed VI fields, and an optional captured revision
/// prevents a slow asynchronous rollout read from overwriting a newer hook.
@MainActor
public final class CodexIngressCoordinator {
    private struct Ledger {
        var revision = 0
        var hookSeen = false
        var hookPromptTurns: Set<String> = []
        var hookFinalTurns: Set<String> = []
        var rolloutSawActiveTurn = false
        var hasIndexTitle = false
        var suppressed = false
        var lastHookAt: Date?
    }

    private let store: SessionStore
    private var ledgers: [String: Ledger] = [:]

    public init(store: SessionStore) {
        self.store = store
    }

    public func revision(for threadID: String) -> Int {
        ledgers[sessionID(threadID)]?.revision ?? 0
    }

    /// VI retains the process writing each rollout so a pre-hook Codex
    /// session remains jumpable. This fallback only fills a missing binding;
    /// a later hook carries the more precise tty/window identity and wins.
    @discardableResult
    public func applyFallbackTerminal(
        threadID: String,
        terminal: TerminalInfo
    ) -> Bool {
        let id = sessionID(threadID)
        guard store.sessions.contains(where: { $0.id == id }),
              terminal.isJumpable,
              store.terminal(for: id)?.isJumpable != true else { return false }
        store.setTerminal(terminal, for: id)
        return true
    }

    public func apply(hook: CodexHookEvent, at date: Date = Date()) {
        let id = hook.sessionID
        var ledger = ledgers[id] ?? Ledger()
        guard !ledger.suppressed else { return }
        let eventDate = hook.capturedAt ?? date
        if let lastHookAt = ledger.lastHookAt, eventDate < lastHookAt { return }
        if hook.kind == .userPromptSubmit,
           !CodexAdmissionRules.shouldAdmit(title: hook.prompt) {
            suppress(id: id, ledger: &ledger)
            return
        }

        var session = store.sessions.first(where: { $0.id == id })
            ?? AgentSession(
                id: id,
                agent: .codex,
                title: "",
                directory: hook.cwd ?? "",
                codexThreadID: hook.threadID,
                state: .running,
                startedAt: eventDate,
                lastActivityAt: eventDate
            )
        session.agent = .codex
        session.codexThreadID = hook.threadID
        session.currentTurnID = hook.turnID ?? session.currentTurnID
        session.currentToolUseID = hook.toolUseID ?? session.currentToolUseID
        session.permissionMode = hook.permissionMode ?? session.permissionMode
        session.model = hook.model ?? session.model
        if let cwd = hook.cwd { session.directory = rootDirectory(session.directory, cwd) }
        if session.gitBranch == nil {
            session.gitBranch = GitIdentity.branch(forDirectory: session.directory)
        }
        if let parent = hook.parentThreadID {
            session.parentSessionID = sessionID(parent)
        }
        session.subagentRole = hook.subagentRole ?? session.subagentRole
        session.subagentNickname = hook.subagentNickname ?? session.subagentNickname
        session.lastActivityAt = eventDate
        store.setTerminal(hook.terminal, for: id)

        switch hook.kind {
        case .sessionStart:
            session.state = .running
        case .userPromptSubmit:
            session.state = .running
            session.recap = nil
            if let prompt = hook.prompt, !prompt.isEmpty {
                session.lastMessage = prompt
                if session.title.isEmpty && !prompt.hasPrefix("/") { session.title = prompt }
            }
            if let turnID = hook.turnID { ledger.hookPromptTurns.insert(turnID) }
            ledger.rolloutSawActiveTurn = false
        case .permissionRequest:
            session.state = .needsApproval
        case .postToolUse:
            break
        case .subagentStop:
            session.subagentCount = max(0, session.subagentCount - 1)
        case .stop:
            session.state = .waitingForInput
            session.currentTool = nil
            session.currentToolDetail = nil
            if let response = hook.finalResponse, !response.isEmpty {
                session.lastAssistantMessage = response
            }
            if let turnID = hook.turnID { ledger.hookFinalTurns.insert(turnID) }
            ledger.rolloutSawActiveTurn = false
        }

        ledger.hookSeen = true
        ledger.lastHookAt = eventDate
        ledger.revision += 1
        ledgers[id] = ledger
        store.upsert(session)
    }

    @discardableResult
    public func apply(
        rollout: CodexRolloutSnapshot,
        observedRevision: Int? = nil,
        at date: Date = Date()
    ) -> Bool {
        guard let threadID = rollout.threadID else { return false }
        let id = sessionID(threadID)
        var ledger = ledgers[id] ?? Ledger()
        guard !ledger.suppressed else { return false }
        if let observedRevision, observedRevision < ledger.revision { return false }

        var session = store.sessions.first(where: { $0.id == id })
            ?? AgentSession(
                id: id,
                agent: .codex,
                title: rollout.firstUserMessage ?? "",
                directory: rollout.cwd ?? "",
                codexThreadID: threadID,
                state: .waitingForInput,
                startedAt: date,
                lastActivityAt: date
            )
        if !CodexAdmissionRules.shouldAdmit(
            title: session.title,
            metadata: rollout.admissionMetadata
        ) {
            suppress(id: id, ledger: &ledger)
            return false
        }
        if let currentTurn = session.currentTurnID,
           !rollout.activeTurnIDs.isEmpty,
           !rollout.activeTurnIDs.contains(currentTurn) {
            return false
        }

        session.codexThreadID = threadID
        if let cwd = rollout.cwd { session.directory = rootDirectory(session.directory, cwd) }
        if session.title.isEmpty, !ledger.hasIndexTitle,
           let first = rollout.firstUserMessage {
            session.title = first
        }
        let turn = session.currentTurnID
        if turn == nil || !ledger.hookPromptTurns.contains(turn!) {
            if let message = rollout.lastUserMessage { session.lastMessage = message }
        }
        if turn == nil || !ledger.hookFinalTurns.contains(turn!) {
            if let response = rollout.lastAgentMessage { session.lastAssistantMessage = response }
        }
        session.currentTool = rollout.currentTool
        session.currentToolDetail = rollout.currentToolDetail
        if let effort = rollout.reasoningEffort {
            session.reasoningEffort = effort
        }
        if let activity = rollout.lastActivityAt { session.lastActivityAt = activity }

        if !rollout.activeTurnIDs.isEmpty {
            ledger.rolloutSawActiveTurn = true
            if session.state != .needsApproval { session.state = .running }
        } else if !ledger.hookSeen || ledger.rolloutSawActiveTurn || session.state == .waitingForInput {
            session.state = .waitingForInput
            session.currentTool = nil
            session.currentToolDetail = nil
            ledger.rolloutSawActiveTurn = false
        }

        ledger.revision += 1
        ledgers[id] = ledger
        store.upsert(session)
        return true
    }

    public func applyTitle(
        threadID: String,
        title: String,
        metadata: [String: String] = [:]
    ) {
        let id = sessionID(threadID)
        var ledger = ledgers[id] ?? Ledger()
        guard !ledger.suppressed else { return }
        guard CodexAdmissionRules.shouldAdmit(title: title, metadata: metadata) else {
            suppress(id: id, ledger: &ledger)
            return
        }
        guard var session = store.sessions.first(where: { $0.id == id }) else {
            ledger.hasIndexTitle = true
            ledger.revision += 1
            ledgers[id] = ledger
            return
        }
        session.title = title
        ledger.hasIndexTitle = true
        ledger.revision += 1
        ledgers[id] = ledger
        store.upsert(session)
    }

    private func suppress(id: String, ledger: inout Ledger) {
        ledger.suppressed = true
        ledger.revision += 1
        ledgers[id] = ledger
        store.remove(id: id)
    }

    private func sessionID(_ threadID: String) -> String {
        threadID.hasPrefix("codex-") ? threadID : "codex-\(threadID)"
    }

    private func rootDirectory(_ current: String, _ cwd: String) -> String {
        guard !current.isEmpty else { return cwd }
        if cwd == current || cwd.hasPrefix(current + "/") { return current }
        if current.hasPrefix(cwd + "/") { return cwd }
        return cwd
    }
}
