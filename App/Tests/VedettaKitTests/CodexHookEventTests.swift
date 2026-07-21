import Foundation
import Testing
@testable import VedettaKit

struct CodexHookEventTests {
    private func envelope(
        _ name: String,
        event extra: [String: Any] = [:],
        terminal: [String: Any] = [
            "tty": "/dev/ttys009",
            "termProgram": "vscode",
            "bundleIdentifier": "com.microsoft.VSCode",
            "pid": 42,
            "windowId": 77,
            "pidChain": [42, 21, 10],
        ]
    ) -> [String: Any] {
        var event: [String: Any] = [
            "hook_event_name": name,
            "session_id": "019f-thread",
            "turn_id": "turn-1",
            "cwd": "/Users/x/Code/vedetta",
            "model": "gpt-5.6-sol",
            "permission_mode": "on-request",
            "transcript_path": "/Users/x/.codex/sessions/rollout.jsonl",
        ]
        event.merge(extra) { _, new in new }
        return ["v": 1, "source": "codex", "terminal": terminal, "event": event]
    }

    @Test func decodesAllSixObservedHookKinds() throws {
        let names = [
            "SessionStart", "UserPromptSubmit", "PermissionRequest",
            "PostToolUse", "SubagentStop", "Stop",
        ]
        for name in names {
            let decoded = try CodexHookEvent(envelope: envelope(name))
            #expect(decoded.kind.rawValue == name)
            #expect(decoded.threadID == "019f-thread")
            #expect(decoded.sessionID == "codex-019f-thread")
        }
    }

    @Test func preservesIdentityPolicyContentAndTerminal() throws {
        let decoded = try CodexHookEvent(envelope: envelope("PermissionRequest", event: [
            "tool_use_id": "call-7",
            "tool_name": "exec",
            "tool_input": ["command": "swift test"],
            "tool_response": ["exit_code": 0],
            "prompt": "run the tests",
            "last_assistant_message": "All green.",
            "parent_session_id": "parent-thread",
            "subagent_role": "reviewer",
            "subagent_nickname": "lint",
            "approvals_reviewer": "guardian",
            "sandbox_policy": ["type": "workspace-write"],
            "auto_reviewed": false,
        ]))

        #expect(decoded.turnID == "turn-1")
        #expect(decoded.toolUseID == "call-7")
        #expect(decoded.toolName == "Bash")
        #expect(decoded.toolInput == .object(["command": .string("swift test")]))
        #expect(decoded.toolOutput == .object(["exit_code": .number(0)]))
        #expect(decoded.prompt == "run the tests")
        #expect(decoded.finalResponse == "All green.")
        #expect(decoded.model == "gpt-5.6-sol")
        #expect(decoded.permissionMode == "on-request")
        #expect(decoded.cwd == "/Users/x/Code/vedetta")
        #expect(decoded.transcriptPath?.hasSuffix("rollout.jsonl") == true)
        #expect(decoded.parentThreadID == "parent-thread")
        #expect(decoded.subagentRole == "reviewer")
        #expect(decoded.subagentNickname == "lint")
        #expect(decoded.configuredReviewer == "guardian")
        #expect(decoded.sandboxPolicy == .object(["type": .string("workspace-write")]))
        #expect(!decoded.autoReviewed)
        #expect(decoded.terminal.tty == "/dev/ttys009")
        #expect(decoded.terminal.windowId == 77)
        #expect(decoded.terminal.pidChain == [42, 21, 10])
    }

    @Test func normalizesObservedShellAliases() throws {
        for name in ["exec", "exec_command", "shell", "local_shell"] {
            let decoded = try CodexHookEvent(envelope: envelope(
                "PostToolUse",
                event: ["tool_name": name]
            ))
            #expect(decoded.toolName == "Bash")
        }
        let patch = try CodexHookEvent(envelope: envelope(
            "PostToolUse",
            event: ["tool_name": "apply_patch"]
        ))
        #expect(patch.toolName == "Edit")
    }

    @Test func acceptsCodexPrefixedIdentityAliases() throws {
        var value = envelope("Stop", event: [
            "codex_thread_id": "thread-original",
            "codex_turn_id": "turn-original",
        ])
        var event = value["event"] as! [String: Any]
        event.removeValue(forKey: "session_id")
        event.removeValue(forKey: "turn_id")
        value["event"] = event

        let decoded = try CodexHookEvent(envelope: value)
        #expect(decoded.threadID == "thread-original")
        #expect(decoded.turnID == "turn-original")
        #expect(decoded.sessionID == "codex-thread-original")
    }

    @Test func normalizedEnvelopeRetainsOriginalCodexIdentifiers() throws {
        let decoded = try CodexHookEvent(envelope: envelope("Stop", event: [
            "last_assistant_message": "Done",
        ]))
        let normalized = decoded.normalizedEnvelope
        let event = normalized["event"] as? [String: Any]
        #expect(normalized["source"] as? String == "codex")
        #expect(event?["session_id"] as? String == "codex-019f-thread")
        #expect(event?["codex_thread_id"] as? String == "019f-thread")
        #expect(event?["codex_turn_id"] as? String == "turn-1")
        #expect(event?["last_assistant_message"] as? String == "Done")
    }

    @Test func stopUsesObservedBenignContinueResponse() throws {
        let stop = try CodexHookEvent(envelope: envelope("Stop"))
        let response = try #require(stop.nonBlockingResponse)
        #expect(response == .object(["continue": .bool(true)]))

        let start = try CodexHookEvent(envelope: envelope("SessionStart"))
        #expect(start.nonBlockingResponse == nil)
    }

    @Test func rejectsWrongSourceUnsupportedKindAndMissingThread() {
        var wrongSource = envelope("SessionStart")
        wrongSource["source"] = "claude"
        #expect(throws: CodexHookEventError.self) {
            try CodexHookEvent(envelope: wrongSource)
        }
        #expect(throws: CodexHookEventError.self) {
            try CodexHookEvent(envelope: envelope("PreToolUse"))
        }

        var missing = envelope("SessionStart")
        var event = missing["event"] as! [String: Any]
        event.removeValue(forKey: "session_id")
        missing["event"] = event
        #expect(throws: CodexHookEventError.self) {
            try CodexHookEvent(envelope: missing)
        }
    }
}
