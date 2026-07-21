import Testing
import Foundation
@testable import VedettaKit

@MainActor
struct SessionEventReducerTests {

    private func envelope(
        _ event: String,
        sessionId: String = "s1",
        cwd: String = "/Users/x/Code/progetto",
        source: String = "claude",
        extra: [String: Any] = [:]
    ) -> [String: Any] {
        var payload: [String: Any] = [
            "hook_event_name": event,
            "session_id": sessionId,
            "cwd": cwd,
        ]
        payload.merge(extra) { _, new in new }
        return [
            "v": 1,
            "source": source,
            "terminal": ["termProgram": "vscode", "tty": "/dev/ttys009"],
            "event": payload,
        ]
    }

    @Test func sessionStartCreatesRunningSession() {
        let store = SessionStore()
        SessionEventReducer.apply(envelope("SessionStart"), to: store)
        #expect(store.sessions.count == 1)
        #expect(store.sessions.first?.state == .running)
        #expect(store.sessions.first?.agent == .claude)
        #expect(store.sessions.first?.directory == "/Users/x/Code/progetto")
    }

    @Test func userPromptSetsTitleAndMessage() {
        let store = SessionStore()
        SessionEventReducer.apply(envelope("SessionStart"), to: store)
        SessionEventReducer.apply(
            envelope("UserPromptSubmit", extra: ["prompt": "sistema il checkout"]),
            to: store
        )
        #expect(store.sessions.first?.title == "sistema il checkout")
        #expect(store.sessions.first?.lastMessage == "sistema il checkout")
        #expect(store.sessions.first?.state == .running)
        // il secondo prompt aggiorna il messaggio ma non il titolo
        SessionEventReducer.apply(
            envelope("UserPromptSubmit", extra: ["prompt": "ora i test"]),
            to: store
        )
        #expect(store.sessions.first?.title == "sistema il checkout")
        #expect(store.sessions.first?.lastMessage == "ora i test")
    }

    @Test func preToolUseSetsToolAndDetail() {
        let store = SessionStore()
        SessionEventReducer.apply(envelope("SessionStart"), to: store)
        SessionEventReducer.apply(
            envelope("PreToolUse", extra: [
                "tool_name": "Bash",
                "tool_input": ["command": "swift test", "description": "Esegue i test"],
            ]),
            to: store
        )
        #expect(store.sessions.first?.currentTool == "Bash")
        #expect(store.sessions.first?.currentToolDetail == "swift test")
        // The tool persists between calls (cleared only on Stop), like VI.
        SessionEventReducer.apply(envelope("PostToolUse", extra: ["tool_name": "Bash"]), to: store)
        #expect(store.sessions.first?.currentTool == "Bash")
        SessionEventReducer.apply(envelope("Stop"), to: store)
        #expect(store.sessions.first?.currentTool == nil)
    }

    @Test func preCompactEntersCompactingAndSessionStartRestores() {
        let store = SessionStore()
        SessionEventReducer.apply(envelope("SessionStart"), to: store)
        SessionEventReducer.apply(
            envelope("PreToolUse", extra: ["tool_name": "Bash", "tool_input": ["command": "ls"]]),
            to: store
        )
        // Manual /compact: purple while compacting, then back to waiting.
        SessionEventReducer.apply(envelope("PreCompact", extra: ["trigger": "manual"]), to: store)
        #expect(store.sessions.first?.state == .compacting)
        #expect(store.sessions.first?.currentTool == nil)
        #expect(store.sessions.first?.compactingStartedAt != nil)
        SessionEventReducer.apply(envelope("SessionStart"), to: store)
        #expect(store.sessions.first?.state == .waitingForInput)
        #expect(store.sessions.first?.compactingStartedAt == nil)
        // Auto-compact happens mid-turn: the agent resumes working.
        SessionEventReducer.apply(envelope("PreCompact", extra: ["trigger": "auto"]), to: store)
        #expect(store.sessions.first?.state == .compacting)
        SessionEventReducer.apply(envelope("SessionStart"), to: store)
        #expect(store.sessions.first?.state == .running)
    }

    @Test func compactingRanksBelowRunningAboveWaiting() {
        #expect(SessionState.running < SessionState.compacting)
        #expect(SessionState.compacting < SessionState.waitingForInput)
    }

    @Test func directoryStaysAtProjectRootWhenAgentCdsIntoSubfolder() {
        let store = SessionStore()
        SessionEventReducer.apply(
            envelope("SessionStart", cwd: "/Users/x/Code/5om"), to: store
        )
        #expect(store.sessions.first?.directoryName == "5om")
        // A cd into a subfolder must not relabel the card.
        SessionEventReducer.apply(
            envelope("PreToolUse", cwd: "/Users/x/Code/5om/theme", extra: [
                "tool_name": "Bash", "tool_input": ["command": "ls"],
            ]),
            to: store
        )
        #expect(store.sessions.first?.directory == "/Users/x/Code/5om")
        // A genuine switch to an unrelated project does update it.
        SessionEventReducer.apply(
            envelope("UserPromptSubmit", cwd: "/Users/x/Code/uptonica", extra: ["prompt": "vai"]),
            to: store
        )
        #expect(store.sessions.first?.directoryName == "uptonica")
    }

    @Test func stopMeansWaitingForInput() {
        let store = SessionStore()
        SessionEventReducer.apply(envelope("SessionStart"), to: store)
        SessionEventReducer.apply(envelope("Stop"), to: store)
        #expect(store.sessions.first?.state == .waitingForInput)
        #expect(store.sessions.first?.currentTool == nil)
    }

    @Test func sessionEndCompletes() {
        let store = SessionStore()
        SessionEventReducer.apply(envelope("SessionStart"), to: store)
        SessionEventReducer.apply(envelope("SessionEnd"), to: store)
        #expect(store.sessions.first?.state == .completed)
    }

    @Test func fileToolDetailUsesPath() {
        let store = SessionStore()
        SessionEventReducer.apply(envelope("SessionStart"), to: store)
        SessionEventReducer.apply(
            envelope("PreToolUse", extra: [
                "tool_name": "Edit",
                "tool_input": ["file_path": "/Users/x/Code/progetto/App/NotchView.swift"],
            ]),
            to: store
        )
        #expect(store.sessions.first?.currentToolDetail == "NotchView.swift")
    }

    @Test func unknownSessionEventsCreateSessionLazily() {
        let store = SessionStore()
        // un evento qualsiasi per una sessione mai vista (app avviata dopo)
        SessionEventReducer.apply(envelope("Stop"), to: store)
        #expect(store.sessions.count == 1)
        #expect(store.sessions.first?.state == .waitingForInput)
    }

    @Test func terminalInfoIsCaptured() {
        let store = SessionStore()
        SessionEventReducer.apply(envelope("SessionStart"), to: store)
        #expect(store.terminal(for: "s1")?.termProgram == "vscode")
        #expect(store.terminal(for: "s1")?.tty == "/dev/ttys009")
    }

    @Test func capturedCodexSessionStartCreatesNamespacedCodexSession() throws {
        let store = SessionStore()
        let decoded = try CodexHookEvent(envelope: envelope(
            "SessionStart",
            sessionId: "019f-thread",
            source: "codex",
            extra: [
                "turn_id": "turn-1",
                "transcript_path": "/Users/x/.codex/sessions/rollout.jsonl",
                "model": "gpt-5.6-sol",
                "permission_mode": "bypassPermissions",
                "source": "startup",
            ]
        ))
        SessionEventReducer.apply(
            decoded.normalizedEnvelope,
            to: store
        )
        #expect(store.sessions.first?.id == "codex-019f-thread")
        #expect(store.sessions.first?.agent == .codex)
        #expect(store.sessions.first?.model == "gpt-5.6-sol")
        #expect(store.sessions.first?.codexThreadID == "019f-thread")
        #expect(store.sessions.first?.currentTurnID == "turn-1")
        #expect(store.sessions.first?.permissionMode == "bypassPermissions")
        #expect(store.sessions.first?.state == .running)
    }

    @Test func codexStopUsesLastAssistantMessageFromHookPayload() {
        let store = SessionStore()
        SessionEventReducer.apply(envelope("SessionStart", source: "codex"), to: store)
        SessionEventReducer.apply(
            envelope("Stop", source: "codex", extra: [
                "turn_id": "turn-1",
                "last_assistant_message": "Implementazione completata.",
                "stop_hook_active": false,
            ]),
            to: store
        )
        #expect(store.sessions.first?.lastAssistantMessage == "Implementazione completata.")
        #expect(store.sessions.first?.state == .waitingForInput)
    }
}
