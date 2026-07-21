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
}
