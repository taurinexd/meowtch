import Testing
import Foundation
@testable import VedettaKit

struct TranscriptFullScanTests {

    private func write(_ lines: [String]) -> String {
        let path = NSTemporaryDirectory() + "vedetta-scan-\(UUID().uuidString).jsonl"
        try? lines.joined(separator: "\n").write(toFile: path, atomically: true, encoding: .utf8)
        return path
    }

    @Test func loadsLiveTasksFromTaskDirectory() throws {
        let base = NSTemporaryDirectory() + "vedetta-tasks-\(UUID().uuidString)"
        let dir = base + "/s1"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: base) }
        try #"{"id":"10","subject":"Seconda","status":"in_progress"}"#
            .write(toFile: dir + "/10.json", atomically: true, encoding: .utf8)
        try #"{"id":"2","subject":"Prima","status":"completed"}"#
            .write(toFile: dir + "/2.json", atomically: true, encoding: .utf8)
        try "42".write(toFile: dir + "/.highwatermark", atomically: true, encoding: .utf8)

        let tasks = try #require(SessionTasks.load(sessionId: "s1", baseDir: base))
        // Numeric order (2 before 10), dotfiles ignored.
        #expect(tasks.items.map(\.id) == ["2", "10"])
        #expect(tasks.done.first?.subject == "Prima")
        #expect(tasks.inProgress.first?.subject == "Seconda")

        // Existing-but-empty directory = empty list (stale cards clear);
        // missing directory = nil (no live task state at all).
        let emptyDir = base + "/s2"
        try FileManager.default.createDirectory(atPath: emptyDir, withIntermediateDirectories: true)
        #expect(SessionTasks.load(sessionId: "s2", baseDir: base)?.isEmpty == true)
        #expect(SessionTasks.load(sessionId: "manca", baseDir: base) == nil)
    }

    @Test func rebuildsTaskListFromCreateAndUpdate() {
        let path = write([
            #"{"type":"user","message":{"role":"user","content":[{"type":"tool_result","content":"Task #1 created successfully: Prima cosa"}]}}"#,
            #"{"type":"user","message":{"role":"user","content":[{"type":"tool_result","content":"Task #2 created successfully: Seconda cosa"}]}}"#,
            #"{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","name":"TaskUpdate","input":{"taskId":"1","status":"completed"}}]}}"#,
            #"{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","name":"TaskUpdate","input":{"taskId":"2","status":"in_progress"}}]}}"#,
        ])
        defer { try? FileManager.default.removeItem(atPath: path) }
        let result = TranscriptFullScan.run(path: path)
        #expect(result.tasks?.items.count == 2)
        #expect(result.tasks?.done.first?.subject == "Prima cosa")
        #expect(result.tasks?.inProgress.first?.subject == "Seconda cosa")
    }

    @Test func deletedTasksDisappearAndSidechainIgnored() {
        let path = write([
            #"{"type":"user","message":{"role":"user","content":[{"type":"tool_result","content":"Task #1 created successfully: Da cancellare"}]}}"#,
            #"{"type":"user","isSidechain":true,"message":{"role":"user","content":[{"type":"tool_result","content":"Task #9 created successfully: Del subagent"}]}}"#,
            #"{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","name":"TaskUpdate","input":{"taskId":"1","status":"deleted"}}]}}"#,
        ])
        defer { try? FileManager.default.removeItem(atPath: path) }
        let result = TranscriptFullScan.run(path: path)
        #expect(result.tasks == nil || result.tasks?.items.isEmpty == true)
    }

    @Test func findsSessionNameAnywhere() {
        let path = write([
            #"{"type":"user","message":{"role":"user","content":[{"type":"text","text":"primo prompt"}]}}"#,
            #"{"type":"user","message":{"role":"user","content":"<system-reminder>\nThe user named this session \"il-mio-nome\". Bla.</system-reminder>"}}"#,
        ])
        defer { try? FileManager.default.removeItem(atPath: path) }
        #expect(TranscriptFullScan.run(path: path).sessionName == "il-mio-nome")
    }
}

struct GitIdentityTests {

    @Test func readsBranchFromHead() throws {
        let root = NSTemporaryDirectory() + "vedetta-git-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: root + "/.git", withIntermediateDirectories: true)
        try "ref: refs/heads/feat/notch-ui\n".write(toFile: root + "/.git/HEAD", atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(atPath: root) }
        #expect(GitIdentity.branch(forDirectory: root) == "feat/notch-ui")
    }

    @Test func walksUpToParentRepo() throws {
        let root = NSTemporaryDirectory() + "vedetta-git-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: root + "/.git", withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: root + "/sub/dir", withIntermediateDirectories: true)
        try "ref: refs/heads/main\n".write(toFile: root + "/.git/HEAD", atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(atPath: root) }
        #expect(GitIdentity.branch(forDirectory: root + "/sub/dir") == "main")
    }

    @Test func nonRepoYieldsNil() {
        let root = NSTemporaryDirectory() + "vedetta-git-\(UUID().uuidString)"
        try? FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: root) }
        #expect(GitIdentity.branch(forDirectory: root) == nil)
    }
}
