import Foundation

/// Sole state writer for Codex sessions. Each ingress source is allowed to
/// update only its observed upstream fields, and an optional captured revision
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
        /// callIDs of request_user_input already announced (sound/expand
        /// fire once per question, not on every rollout re-read).
        var announcedQuestions: Set<String> = []
        /// True while the attention state was set by a rollout question —
        /// the only needsApproval the rollout itself may release.
        var questionPending = false
    }

    private let store: SessionStore
    private var ledgers: [String: Ledger] = [:]
    /// Fired once per new request_user_input question (the TUI holds the
    /// answer; the notch mirrors the question and plays its chirp).
    public var onUserInputRequest: (@MainActor () -> Void)?

    public init(store: SessionStore) {
        self.store = store
    }

    public func revision(for threadID: String) -> Int {
        ledgers[sessionID(threadID)]?.revision ?? 0
    }

    /// The original retains the process writing each rollout so a pre-hook Codex
    /// session remains jumpable. A resumed thread may acquire a new writer,
    /// so rollout-derived bindings can refresh one another. A later hook
    /// carries the more precise tty/window identity and always wins.
    @discardableResult
    public func applyFallbackTerminal(
        threadID: String,
        terminal: TerminalInfo
    ) -> Bool {
        let id = sessionID(threadID)
        guard store.sessions.contains(where: { $0.id == id }),
              terminal.isJumpable else { return false }
        if let existing = store.terminal(for: id), existing.isJumpable {
            let existingIsFallback = existing.tty == nil && existing.windowId == nil
            guard existingIsFallback, existing.pid != terminal.pid else { return false }
        }
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
        session.subagentKind = hook.subagentKind ?? session.subagentKind
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
            // Codex has no PreToolUse hook: an executed tool is the only
            // signal that a pending approval was decided (in the terminal,
            // or in bypass). Without this the orange state has no way back
            // until Stop and the stale interrupt hijacks the panel.
            if session.state == .needsApproval { session.state = .running }
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
        // A rollout describing a different (real) turn than the hooks' current
        // one is a cross-turn straggler. Anonymous ids — the file omitted
        // turn_id — can never match a hook identity and must not reject.
        let namedTurns = rollout.activeTurnIDs.filter {
            !$0.hasPrefix(CodexRolloutTailer.anonymousTurnPrefix)
        }
        if let currentTurn = session.currentTurnID,
           !namedTurns.isEmpty,
           !namedTurns.contains(currentTurn) {
            return false
        }

        session.codexThreadID = threadID
        if let cwd = rollout.cwd { session.directory = rootDirectory(session.directory, cwd) }
        if let parent = rollout.subagentParentThreadID {
            session.parentSessionID = sessionID(parent)
        }
        session.subagentKind = rollout.subagentKind ?? session.subagentKind
        session.subagentRole = rollout.subagentRole ?? session.subagentRole
        session.subagentNickname = rollout.subagentNickname ?? session.subagentNickname
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

        // The file can lag the hooks: right after a Stop hook the rollout may
        // still miss its task_complete. A turn the hooks already finalized
        // must not count as live activity, or the card flips back to blue.
        let liveTurns = rollout.activeTurnIDs.subtracting(ledger.hookFinalTurns)
        if let question = rollout.pendingUserInputQuestion {
            // request_user_input never reaches the hooks (TUI-only): the
            // rollout is the sole signal that the model is waiting for the
            // USER mid-turn. Attention state + the question on the card;
            // it resolves itself when the answer lands in the file.
            session.state = .needsApproval
            session.currentTool = "Question"
            session.currentToolDetail = question.question
            // The TUI's numbered picker follows the payload's option order:
            // safe to answer remotely only for a single question.
            session.pendingQuestionOptions =
                question.isMultiQuestion || question.optionLabels.isEmpty
                    ? nil : question.optionLabels
            ledger.rolloutSawActiveTurn = !liveTurns.isEmpty
            ledger.questionPending = true
            let newQuestions = Set(rollout.pendingUserInput.keys)
                .subtracting(ledger.announcedQuestions)
            if !newQuestions.isEmpty {
                ledger.announcedQuestions.formUnion(newQuestions)
                onUserInputRequest?()
            }
        } else {
            if ledger.questionPending {
                // The user answered in the TUI: release the attention state
                // (only a question's needsApproval — a hook approval's is
                // owned by the hook flow).
                ledger.questionPending = false
                ledger.announcedQuestions.removeAll()
                session.pendingQuestionOptions = nil
                if session.state == .needsApproval {
                    session.state = liveTurns.isEmpty ? .waitingForInput : .running
                }
            }
            if !liveTurns.isEmpty {
                ledger.rolloutSawActiveTurn = true
                if session.state != .needsApproval { session.state = .running }
            } else if !ledger.hookSeen || ledger.rolloutSawActiveTurn
                        || session.state == .waitingForInput {
                session.state = .waitingForInput
                session.currentTool = nil
                session.currentToolDetail = nil
                ledger.rolloutSawActiveTurn = false
            }
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
