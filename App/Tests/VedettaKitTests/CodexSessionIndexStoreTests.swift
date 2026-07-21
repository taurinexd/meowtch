import Foundation
import Testing
@testable import VedettaKit

struct CodexSessionIndexStoreTests {
    private func temporaryFile() throws -> (directory: URL, file: URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("vedetta-index-tests")
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return (directory, directory.appendingPathComponent("session_index.jsonl"))
    }

    @Test func latestRenameWinsIncrementally() throws {
        let temp = try temporaryFile()
        defer { try? FileManager.default.removeItem(at: temp.directory) }
        try Data(("""
        {"id":"thread-1","thread_name":"First prompt"}
        """ + "\n").utf8).write(to: temp.file)
        var index = CodexSessionIndexStore()
        #expect(try index.read(from: temp.file)["thread-1"] == "First prompt")

        let handle = try FileHandle(forWritingTo: temp.file)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("{\"id\":\"thread-1\",\"thread_name\":\"codex-vedetta\"}\n".utf8))
        try handle.close()
        #expect(try index.read(from: temp.file)["thread-1"] == "codex-vedetta")
    }

    @Test func buffersPartialLinesAndResetsOnReplacement() throws {
        let temp = try temporaryFile()
        defer { try? FileManager.default.removeItem(at: temp.directory) }
        try Data("{\"id\":\"thread-1\",\"thread_name\":\"par".utf8).write(to: temp.file)
        var index = CodexSessionIndexStore()
        #expect(try index.read(from: temp.file).isEmpty)

        let handle = try FileHandle(forWritingTo: temp.file)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("tial\"}\n".utf8))
        try handle.close()
        #expect(try index.read(from: temp.file)["thread-1"] == "partial")

        try Data("{\"id\":\"thread-2\",\"thread_name\":\"replacement\"}\n".utf8)
            .write(to: temp.file, options: .atomic)
        let replaced = try index.read(from: temp.file)
        #expect(replaced["thread-1"] == nil)
        #expect(replaced["thread-2"] == "replacement")
    }

    @Test func ignoresEmptyAndMalformedEntries() throws {
        let temp = try temporaryFile()
        defer { try? FileManager.default.removeItem(at: temp.directory) }
        try Data("""
        not-json
        {"id":"thread-1","thread_name":""}
        {"thread_name":"missing id"}
        {"id":"thread-2","thread_name":"valid"}
        """.appending("\n").utf8).write(to: temp.file)
        var index = CodexSessionIndexStore()
        #expect(try index.read(from: temp.file) == ["thread-2": "valid"])
    }
}
