import Foundation
import Testing
@testable import VedettaKit

@MainActor
struct CodexIngressCoordinatorTests {
    private func hook(
        _ kind: String,
        thread: String = "thread-1",
        turn: String = "turn-1",
        extra: [String: Any] = [:]
    ) throws -> CodexHookEvent {
        var event: [String: Any] = [
            "hook_event_name": kind,
            "session_id": thread,
            "turn_id": turn,
            "cwd": "/repo",
        ]
        event.merge(extra) { _, new in new }
        return try CodexHookEvent(envelope: [
            "source": "codex",
            "terminal": [
                "tty": "/dev/ttys001",
                "termProgram": "vscode",
                "bundleIdentifier": "com.microsoft.VSCode",
                "pid": 999,
                "windowId": 123,
                "pidChain": [999, 100],
            ],
            "event": event,
        ])
    }

    private func rollout(
        thread: String = "thread-1",
        activeTurns: Set<String> = [],
        user: String? = nil,
        agent: String? = nil,
        reasoningEffort: String? = nil,
        tools: [String: CodexRolloutTool] = [:]
    ) -> CodexRolloutSnapshot {
        var snapshot = CodexRolloutSnapshot()
        snapshot.threadID = thread
        snapshot.cwd = "/repo"
        snapshot.firstUserMessage = user
        snapshot.lastUserMessage = user
        snapshot.lastAgentMessage = agent
        snapshot.reasoningEffort = reasoningEffort
        snapshot.activeTurnIDs = activeTurns
        snapshot.openTools = tools
        return snapshot
    }

    @Test func rolloutReasoningEffortReachesSessionAndLatestValueWins() {
        let store = SessionStore()
        let coordinator = CodexIngressCoordinator(store: store)

        #expect(coordinator.apply(rollout: rollout(
            user: "inspect",
            reasoningEffort: "high"
        )))
        #expect(store.sessions.first?.reasoningEffort == "high")

        #expect(coordinator.apply(rollout: rollout(reasoningEffort: "xhigh")))
        #expect(store.sessions.first?.reasoningEffort == "xhigh")
    }

    @Test func enforcesFieldAuthorityAcrossHookRolloutAndIndex() throws {
        let store = SessionStore()
        let coordinator = CodexIngressCoordinator(store: store)
        coordinator.apply(hook: try hook(
            "UserPromptSubmit",
            extra: ["prompt": "hook prompt", "model": "gpt-5.6"]
        ))
        let tool = CodexRolloutTool(callID: "call-1", name: "Bash", detail: "swift test")
        #expect(coordinator.apply(rollout: rollout(
            activeTurns: ["turn-1"],
            user: "stale rollout prompt",
            agent: "draft",
            tools: ["call-1": tool]
        )))
        coordinator.applyTitle(threadID: "thread-1", title: "Renamed live")

        let running = try #require(store.sessions.first)
        #expect(running.title == "Renamed live")
        #expect(running.lastMessage == "hook prompt")
        #expect(running.currentTool == "Bash")
        #expect(running.currentToolDetail == "swift test")
        #expect(running.state == .running)

        coordinator.apply(hook: try hook(
            "Stop",
            extra: ["last_assistant_message": "hook final"]
        ))
        #expect(coordinator.apply(rollout: rollout(agent: "stale rollout final")))
        #expect(store.sessions.first?.lastAssistantMessage == "hook final")
        #expect(store.sessions.first?.state == .waitingForInput)
    }

    @Test func postToolUseClearsATerminalDecidedApproval() throws {
        let store = SessionStore()
        let coordinator = CodexIngressCoordinator(store: store)
        coordinator.apply(hook: try hook("UserPromptSubmit", extra: ["prompt": "run it"]))
        coordinator.apply(hook: try hook("PermissionRequest", extra: ["tool_name": "shell"]))
        #expect(store.sessions.first?.state == .needsApproval)

        // The user approved in the terminal: the executed tool's PostToolUse
        // is the only Codex signal that the decision was made.
        coordinator.apply(hook: try hook("PostToolUse", extra: ["tool_name": "shell"]))
        #expect(store.sessions.first?.state == .running)
    }

    @Test func rolloutActivityPreservesAPendingApproval() throws {
        let store = SessionStore()
        let coordinator = CodexIngressCoordinator(store: store)
        coordinator.apply(hook: try hook("UserPromptSubmit", extra: ["prompt": "run it"]))
        coordinator.apply(hook: try hook("PermissionRequest", extra: ["tool_name": "shell"]))

        #expect(coordinator.apply(rollout: rollout(activeTurns: ["turn-1"])))
        #expect(store.sessions.first?.state == .needsApproval)
    }

    @Test func laggingRolloutCannotRevertAHookFinalizedTurn() throws {
        let store = SessionStore()
        let coordinator = CodexIngressCoordinator(store: store)
        coordinator.apply(hook: try hook("UserPromptSubmit", extra: ["prompt": "go"]))
        coordinator.apply(hook: try hook("Stop", extra: ["last_assistant_message": "done"]))
        #expect(store.sessions.first?.state == .waitingForInput)

        // The rollout file has not flushed task_complete yet: its stale
        // active turn must not flip the finished card back to running.
        let tool = CodexRolloutTool(callID: "call-9", name: "Bash", detail: "sleep 1")
        #expect(coordinator.apply(rollout: rollout(
            activeTurns: ["turn-1"],
            tools: ["call-9": tool]
        )))
        #expect(store.sessions.first?.state == .waitingForInput)
        #expect(store.sessions.first?.currentTool == nil)
    }

    @Test func anonymousRolloutTurnsDoNotRejectAHookIdentifiedSession() throws {
        let store = SessionStore()
        let coordinator = CodexIngressCoordinator(store: store)
        coordinator.apply(hook: try hook("UserPromptSubmit", extra: ["prompt": "go"]))

        // The file omitted turn_id: its synthetic id can never match the
        // hook's turn and must not block enrichment.
        let tool = CodexRolloutTool(callID: "call-3", name: "Bash", detail: "make app")
        #expect(coordinator.apply(rollout: rollout(
            activeTurns: [CodexRolloutTailer.anonymousTurnPrefix + "1"],
            tools: ["call-3": tool]
        )))
        #expect(store.sessions.first?.currentTool == "Bash")
        #expect(store.sessions.first?.state == .running)
    }

    @Test func rolloutQuestionRaisesAttentionAndReleasesOnAnswer() throws {
        let store = SessionStore()
        let coordinator = CodexIngressCoordinator(store: store)
        var announcements = 0
        coordinator.onUserInputRequest = { announcements += 1 }
        coordinator.apply(hook: try hook("UserPromptSubmit", extra: ["prompt": "go"]))

        var asking = rollout(activeTurns: ["turn-1"])
        asking.pendingUserInput = ["call-q": [
            CodexPendingQuestion(question: "Quale prova vuoi fare?",
                                 optionLabels: ["Scegli A", "Scegli B"]),
            CodexPendingQuestion(question: "E poi?", optionLabels: ["X", "Y"]),
        ]]
        #expect(coordinator.apply(rollout: asking))
        #expect(store.sessions.first?.state == .needsApproval)
        #expect(store.sessions.first?.currentTool == "Question")
        #expect(store.sessions.first?.currentToolDetail == "Quale prova vuoi fare? (+1)")
        #expect(store.sessions.first?.pendingCodexQuestions?.count == 2)
        #expect(announcements == 1)

        // Re-reads of the same question do not re-announce.
        #expect(coordinator.apply(rollout: asking))
        #expect(announcements == 1)

        // Answered in the TUI: the attention state releases on its own.
        #expect(coordinator.apply(rollout: rollout(activeTurns: ["turn-1"])))
        #expect(store.sessions.first?.state == .running)
        #expect(store.sessions.first?.pendingCodexQuestions == nil)
    }

    @Test func rejectsRolloutReadStartedBeforeNewerHookRevision() throws {
        let store = SessionStore()
        let coordinator = CodexIngressCoordinator(store: store)
        coordinator.apply(hook: try hook("SessionStart"))
        let captured = coordinator.revision(for: "thread-1")
        coordinator.apply(hook: try hook("Stop"))
        let stale = rollout(
            activeTurns: ["turn-1"],
            tools: ["call-1": CodexRolloutTool(callID: "call-1", name: "Bash", detail: "old")]
        )

        #expect(!coordinator.apply(rollout: stale, observedRevision: captured))
        #expect(store.sessions.first?.state == .waitingForInput)
        #expect(store.sessions.first?.currentTool == nil)
    }

    @Test func delayedOlderHookCannotUndoNewerLifecycleState() throws {
        let store = SessionStore()
        let coordinator = CodexIngressCoordinator(store: store)
        coordinator.apply(
            hook: try hook("Stop"),
            at: Date(timeIntervalSince1970: 101)
        )

        coordinator.apply(
            hook: try hook("SessionStart"),
            at: Date(timeIntervalSince1970: 100)
        )

        #expect(store.sessions.first?.state == .waitingForInput)
        #expect(store.sessions.first?.lastActivityAt == Date(timeIntervalSince1970: 101))
    }

    @Test func rolloutCompletionRecoversMissingStopButRejectsAnotherActiveTurn() throws {
        let store = SessionStore()
        let coordinator = CodexIngressCoordinator(store: store)
        coordinator.apply(hook: try hook("UserPromptSubmit", extra: ["prompt": "work"]))

        #expect(!coordinator.apply(rollout: rollout(activeTurns: ["other-turn"])))
        #expect(store.sessions.first?.state == .running)
        #expect(coordinator.apply(rollout: rollout(activeTurns: ["turn-1"])))
        #expect(coordinator.apply(rollout: rollout(activeTurns: [])))
        #expect(store.sessions.first?.state == .waitingForInput)
    }

    @Test func lateWorkerClassificationRemovesCardAndTerminal() throws {
        let store = SessionStore()
        let coordinator = CodexIngressCoordinator(store: store)
        coordinator.apply(hook: try hook("SessionStart"))
        #expect(store.terminal(for: "codex-thread-1") != nil)

        coordinator.applyTitle(
            threadID: "thread-1",
            title: "Codex Companion Task: hidden worker"
        )
        #expect(store.sessions.isEmpty)
        #expect(store.terminal(for: "codex-thread-1") == nil)
    }

    @Test func rolloutOnlySessionConvergesWhenHookArrives() throws {
        let store = SessionStore()
        let coordinator = CodexIngressCoordinator(store: store)
        #expect(coordinator.apply(rollout: rollout(
            activeTurns: ["turn-1"], user: "provisional"
        )))
        coordinator.apply(hook: try hook(
            "UserPromptSubmit", extra: ["prompt": "authoritative"]
        ))

        #expect(store.sessions.count == 1)
        #expect(store.sessions.first?.id == "codex-thread-1")
        #expect(store.sessions.first?.lastMessage == "authoritative")
    }

    @Test func rolloutOriginSuppressesDesktopAndInternalCompanionSessions() {
        for originator in ["Codex Desktop", "Claude Code"] {
            let store = SessionStore()
            let coordinator = CodexIngressCoordinator(store: store)
            var snapshot = rollout(user: "must stay hidden")
            snapshot.originator = originator
            snapshot.source = "vscode"

            #expect(!coordinator.apply(rollout: snapshot))
            #expect(store.sessions.isEmpty)
        }
    }

    @Test func rolloutWriterTerminalFillsGapButNeverReplacesHookIdentity() throws {
        let store = SessionStore()
        let coordinator = CodexIngressCoordinator(store: store)
        #expect(coordinator.apply(rollout: rollout(user: "provisional")))
        let fallback = TerminalInfo(
            termProgram: "vscode",
            bundleIdentifier: "com.microsoft.VSCode",
            pid: 15557,
            pidChain: [15557, 15549, 10814, 8026, 8004]
        )

        #expect(coordinator.applyFallbackTerminal(
            threadID: "thread-1",
            terminal: fallback
        ))
        #expect(store.terminal(for: "codex-thread-1") == fallback)

        let resumedFallback = TerminalInfo(
            termProgram: "vscode",
            bundleIdentifier: "com.microsoft.VSCode",
            pid: 20000,
            pidChain: [20000, 19999, 10814, 8026, 8004]
        )
        #expect(coordinator.applyFallbackTerminal(
            threadID: "thread-1",
            terminal: resumedFallback
        ))
        #expect(store.terminal(for: "codex-thread-1") == resumedFallback)

        coordinator.apply(hook: try hook("SessionStart"))
        let hookIdentity = try #require(store.terminal(for: "codex-thread-1"))
        #expect(hookIdentity.tty == "/dev/ttys001")
        #expect(!coordinator.applyFallbackTerminal(
            threadID: "thread-1",
            terminal: fallback
        ))
        #expect(store.terminal(for: "codex-thread-1") == hookIdentity)
    }

    @Test func retainsParentAwareSubagentDetail() throws {
        let store = SessionStore()
        let coordinator = CodexIngressCoordinator(store: store)
        coordinator.apply(hook: try hook("SubagentStop", extra: [
            "parent_session_id": "parent-thread",
            "subagent_kind": "reviewer",
            "subagent_role": "reviewer",
            "subagent_nickname": "security",
        ]))

        #expect(store.sessions.first?.parentSessionID == "codex-parent-thread")
        #expect(store.sessions.first?.subagentKind == "reviewer")
        #expect(store.sessions.first?.subagentRole == "reviewer")
        #expect(store.sessions.first?.subagentNickname == "security")
    }

    @Test func rolloutBootstrapRetainsSubagentIdentityBeforeHooksArrive() {
        let store = SessionStore()
        let coordinator = CodexIngressCoordinator(store: store)
        var snapshot = rollout(user: "review the patch")
        snapshot.subagentKind = "reviewer"
        snapshot.subagentParentThreadID = "parent-thread"
        snapshot.subagentRole = "review"
        snapshot.subagentNickname = "security"

        #expect(coordinator.apply(rollout: snapshot))
        #expect(store.sessions.first?.subagentKind == "reviewer")
        #expect(store.sessions.first?.parentSessionID == "codex-parent-thread")
        #expect(store.sessions.first?.subagentRole == "review")
        #expect(store.sessions.first?.subagentNickname == "security")
    }
}
