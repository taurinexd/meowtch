import Foundation
import Testing
@testable import VedettaKit

struct CodexRolloutTailerTests {
    private func temporaryFile() throws -> (directory: URL, file: URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("vedetta-rollout-tests")
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return (directory, directory.appendingPathComponent("rollout-test.jsonl"))
    }

    @Test func readsOnlyAppendsAndBuffersIncompleteLine() throws {
        let temp = try temporaryFile()
        defer { try? FileManager.default.removeItem(at: temp.directory) }
        let first = """
        {"type":"session_meta","payload":{"id":"thread-1","cwd":"/repo"}}
        {"type":"event_msg","payload":{"type":"user_message","message":"par
        """
        try Data(first.utf8).write(to: temp.file)
        var tailer = CodexRolloutTailer()

        let initial = try tailer.read(from: temp.file)
        #expect(initial.threadID == "thread-1")
        #expect(initial.lastUserMessage == nil)
        let offsetAfterFirstRead = tailer.offset

        let handle = try FileHandle(forWritingTo: temp.file)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("tial\"}}\n".utf8))
        try handle.close()
        let appended = try tailer.read(from: temp.file)
        #expect(appended.lastUserMessage == "partial")
        #expect(tailer.offset > offsetAfterFirstRead)

        let unchangedOffset = tailer.offset
        _ = try tailer.read(from: temp.file)
        #expect(tailer.offset == unchangedOffset)
    }

    @Test func resetsAfterTruncationOrReplacement() throws {
        let temp = try temporaryFile()
        defer { try? FileManager.default.removeItem(at: temp.directory) }
        try Data(("""
        {"type":"session_meta","payload":{"id":"old","cwd":"/old"}}
        {"type":"event_msg","payload":{"type":"user_message","message":"old prompt"}}
        """ + "\n").utf8).write(to: temp.file)
        var tailer = CodexRolloutTailer()
        #expect(try tailer.read(from: temp.file).threadID == "old")

        try Data(("""
        {"type":"session_meta","payload":{"id":"new","cwd":"/new"}}
        """ + "\n").utf8).write(to: temp.file, options: .atomic)
        let rebuilt = try tailer.read(from: temp.file)
        #expect(rebuilt.threadID == "new")
        #expect(rebuilt.cwd == "/new")
        #expect(rebuilt.lastUserMessage == nil)
    }

    @Test func parsesFractionalSecondTimestampsIntoActivity() throws {
        let temp = try temporaryFile()
        defer { try? FileManager.default.removeItem(at: temp.directory) }
        try Data(("""
        {"type":"session_meta","payload":{"id":"thread-1","cwd":"/repo"}}
        {"type":"event_msg","payload":{"type":"task_started","turn_id":"turn-1","started_at":"2026-07-21T08:20:12.128Z"}}
        """ + "\n").utf8).write(to: temp.file)
        var tailer = CodexRolloutTailer()

        // Codex stamps milliseconds; the plain ISO formatter returns nil
        // for them and lastActivityAt silently never advanced.
        let snapshot = try tailer.read(from: temp.file)
        let expected = try #require(ISO8601DateFormatter().date(from: "2026-07-21T08:20:12Z"))
        let parsed = try #require(snapshot.lastActivityAt)
        #expect(abs(parsed.timeIntervalSince(expected) - 0.128) < 0.001)
    }

    @Test func mirrorsRequestUserInputAsPendingQuestion() throws {
        let temp = try temporaryFile()
        defer { try? FileManager.default.removeItem(at: temp.directory) }
        // Real 0.145 shape: arguments is JSON-in-string with questions[].
        try Data(("""
        {"type":"session_meta","payload":{"id":"thread-1","cwd":"/repo"}}
        {"type":"event_msg","payload":{"type":"task_started","turn_id":"turn-1"}}
        {"type":"response_item","payload":{"type":"function_call","call_id":"call-q","name":"request_user_input","arguments":"{\\"questions\\":[{\\"header\\":\\"Test\\",\\"id\\":\\"t\\",\\"question\\":\\"Quale prova vuoi fare?\\",\\"options\\":[{\\"label\\":\\"A\\"},{\\"label\\":\\"B\\"}]}]}"}}
        """ + "\n").utf8).write(to: temp.file)
        var tailer = CodexRolloutTailer()

        let pending = try tailer.read(from: temp.file)
        let question = try #require(pending.pendingUserInputQuestion)
        #expect(question.question == "Quale prova vuoi fare?")
        #expect(question.optionLabels == ["A", "B"])
        #expect(!question.isMultiQuestion)
        #expect(pending.currentTool == "Question")

        // The user answers in the TUI: the output releases the question.
        let handle = try FileHandle(forWritingTo: temp.file)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(("""
        {"type":"response_item","payload":{"type":"function_call_output","call_id":"call-q","output":"{\\"answers\\":{}}"}}
        """ + "\n").utf8))
        try handle.close()
        let answered = try tailer.read(from: temp.file)
        #expect(answered.pendingUserInputQuestion == nil)
        #expect(answered.currentTool == nil)
    }

    @Test func tracksParallelCallsByIDAndReadsCustomInput() throws {
        let temp = try temporaryFile()
        defer { try? FileManager.default.removeItem(at: temp.directory) }
        try Data(("""
        {"type":"session_meta","payload":{"id":"thread-1","cwd":"/repo"}}
        {"type":"event_msg","payload":{"type":"task_started","turn_id":"turn-1"}}
        {"type":"response_item","payload":{"type":"function_call","call_id":"call-1","name":"exec","arguments":"{\\"command\\":\\"swift test\\"}"}}
        {"type":"response_item","payload":{"type":"custom_tool_call","call_id":"call-2","name":"apply_patch","input":{"path":"Sources/App.swift"}}}
        {"type":"response_item","payload":{"type":"function_call_output","call_id":"call-1","output":"ok"}}
        """ + "\n").utf8).write(to: temp.file)
        var tailer = CodexRolloutTailer()

        let snapshot = try tailer.read(from: temp.file)
        #expect(snapshot.state == .running)
        #expect(Set(snapshot.openTools.keys) == ["call-2"])
        #expect(snapshot.currentTool == "Edit")
        #expect(snapshot.currentToolDetail == "Sources/App.swift")
    }

    @Test func rolloutContinuesEnrichingAfterHooksAppear() throws {
        let temp = try temporaryFile()
        defer { try? FileManager.default.removeItem(at: temp.directory) }
        try Data(("""
        {"type":"session_meta","payload":{"id":"thread-1","cwd":"/repo"}}
        """ + "\n").utf8).write(to: temp.file)
        var tailer = CodexRolloutTailer()
        _ = try tailer.read(from: temp.file)

        let handle = try FileHandle(forWritingTo: temp.file)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(("""
        {"type":"event_msg","payload":{"type":"agent_message","message":"rollout enrichment"}}
        """ + "\n").utf8))
        try handle.close()

        #expect(try tailer.read(from: temp.file).lastAgentMessage == "rollout enrichment")
    }

    @Test func readsDirectReasoningEffortFromTurnContext() {
        var tailer = CodexRolloutTailer()
        let snapshot = tailer.ingest(Data(("""
        {"type":"turn_context","payload":{"effort":"high","collaboration_mode":{"settings":{"reasoning_effort":"low"}}}}
        """ + "\n").utf8))

        #expect(snapshot.reasoningEffort == "high")
    }

    @Test func fallsBackToNestedReasoningEffortFromTurnContext() {
        var tailer = CodexRolloutTailer()
        let snapshot = tailer.ingest(Data(("""
        {"type":"turn_context","payload":{"collaboration_mode":{"settings":{"reasoning_effort":"medium"}}}}
        """ + "\n").utf8))

        #expect(snapshot.reasoningEffort == "medium")
    }

    @Test func abortedTurnCannotKeepSessionRunning() {
        var tailer = CodexRolloutTailer()
        let snapshot = tailer.ingest(Data(("""
        {"type":"event_msg","payload":{"type":"task_started","turn_id":"turn-aborted"}}
        {"type":"response_item","payload":{"type":"function_call","call_id":"call-1","name":"exec","arguments":"{\\"command\\":\\"pwd\\"}"}}
        {"type":"event_msg","payload":{"type":"turn_aborted","turn_id":"turn-aborted"}}
        """ + "\n").utf8))

        #expect(snapshot.state == .waiting)
        #expect(snapshot.activeTurnIDs.isEmpty)
        #expect(snapshot.openTools.isEmpty)
    }

    @Test func threadRollbackClearsAllInflightState() {
        var tailer = CodexRolloutTailer()
        let snapshot = tailer.ingest(Data(("""
        {"type":"event_msg","payload":{"type":"task_started","turn_id":"turn-1"}}
        {"type":"response_item","payload":{"type":"function_call","call_id":"call-1","name":"exec","arguments":"{\\"command\\":\\"pwd\\"}"}}
        {"type":"event_msg","payload":{"type":"thread_rolled_back"}}
        """ + "\n").utf8))

        #expect(snapshot.state == .waiting)
        #expect(snapshot.activeTurnIDs.isEmpty)
        #expect(snapshot.openTools.isEmpty)
    }

    @Test func completedTurnClearsUnmatchedOpenTools() {
        var tailer = CodexRolloutTailer()
        let snapshot = tailer.ingest(Data(("""
        {"type":"event_msg","payload":{"type":"task_started","turn_id":"turn-1"}}
        {"type":"response_item","payload":{"type":"function_call","call_id":"call-without-output","name":"exec","arguments":"{\\"command\\":\\"pwd\\"}"}}
        {"type":"event_msg","payload":{"type":"task_complete","turn_id":"turn-1"}}
        """ + "\n").utf8))

        #expect(snapshot.state == .waiting)
        #expect(snapshot.openTools.isEmpty)
    }

    @Test func parsesTerminalOriginForAdmissionAndJumpParity() {
        var tailer = CodexRolloutTailer()
        let snapshot = tailer.ingest(Data(("""
        {"type":"session_meta","payload":{"session_id":"thread-1","cwd":"/repo","originator":"codex-tui","source":"cli","thread_source":"user","origin":"terminal","subagent_kind":"reviewer","subagent_parent_thread_id":"parent-1","subagent_nickname":"security","subagent_role":"review"}}
        """ + "\n").utf8))

        #expect(snapshot.originator == "codex-tui")
        #expect(snapshot.source == "cli")
        #expect(snapshot.threadSource == "user")
        #expect(snapshot.origin == "terminal")
        #expect(snapshot.subagentKind == "reviewer")
        #expect(snapshot.subagentParentThreadID == "parent-1")
        #expect(snapshot.subagentNickname == "security")
        #expect(snapshot.subagentRole == "review")
    }
}
