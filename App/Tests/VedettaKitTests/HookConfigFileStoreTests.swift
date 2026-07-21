import Foundation
import Testing
@testable import VedettaKit

struct HookConfigFileStoreTests {
    @Test func readsClaudeJSONWithLineCommentsOutsideStrings() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("settings.json")
        try Data("""
        {
          // user explanation
          "url": "https://example.test/path//segment",
          "hooks": {}
        }
        """.utf8).write(to: file)

        let result = try HookConfigFileStore().read(at: file)
        #expect(result["url"] as? String == "https://example.test/path//segment")
        #expect(result["hooks"] as? [String: Any] != nil)
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("vedetta-hook-store-tests-")
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test func mutatePreservesUserCommentsOrderAndLiterals() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let config = root.appendingPathComponent("settings.json")
        let backups = root.appendingPathComponent("backups")
        try Data("""
        {
          // keep me
          "model": "opus",
          "hooks": {
            "Stop": [
              { "hooks": [{ "command": "afplay done.wav", "type": "command" }] }
            ]
          },
          "timeout": 86400
        }
        """.utf8).write(to: config)
        let store = HookConfigFileStore(now: { Date(timeIntervalSince1970: 0) })

        _ = try store.mutate(
            at: config,
            backupDirectory: backups,
            backupName: "settings.json"
        ) { settings in
            var settings = settings
            var hooks = settings["hooks"] as? [String: Any] ?? [:]
            hooks["SessionStart"] = [["hooks": [["command": "vedetta", "type": "command"]]]]
            settings["hooks"] = hooks
            return (settings, true)
        }

        let written = String(
            decoding: try Data(contentsOf: config), as: UTF8.self
        )
        #expect(written.contains("// keep me"))
        #expect(written.contains("afplay done.wav"))
        #expect(written.contains("\"timeout\": 86400"))
        #expect(written.contains("\"SessionStart\""))
        // The user's ordering survives: model stays before hooks.
        let model = try #require(written.range(of: "\"model\""))
        let hooks = try #require(written.range(of: "\"hooks\""))
        #expect(model.lowerBound < hooks.lowerBound)
        // And the file still reads back as the transform's result.
        let reread = try store.read(at: config)
        #expect((reread["hooks"] as? [String: Any])?.count == 2)
    }

    @Test func createsMissingConfigurationWithoutBackup() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let config = root.appendingPathComponent("agent/hooks.json")
        let backups = root.appendingPathComponent("backups")
        let store = HookConfigFileStore(now: { Date(timeIntervalSince1970: 0) })

        let result = try store.mutate(
            at: config,
            backupDirectory: backups,
            backupName: "hooks.json"
        ) { settings in
            var settings = settings
            settings["hooks"] = ["Stop": []]
            return (settings, true)
        }

        #expect(result.changed)
        #expect(result.backupURL == nil)
        #expect(FileManager.default.fileExists(atPath: config.path))
        let stored = try store.read(at: config)
        #expect(stored["hooks"] != nil)
    }

    @Test func backsUpExistingFileBeforeMergeAndPreservesUnrelatedKeys() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let config = root.appendingPathComponent("hooks.json")
        let backups = root.appendingPathComponent("backups")
        let original = #"{"notify":["keep-me"],"custom":true}"#.data(using: .utf8)!
        try original.write(to: config)
        let store = HookConfigFileStore(now: { Date(timeIntervalSince1970: 0) })

        let result = try store.mutate(
            at: config,
            backupDirectory: backups,
            backupName: "hooks.json"
        ) { settings in
            var settings = settings
            settings["hooks"] = ["Stop": []]
            return (settings, true)
        }

        let backupURL = try #require(result.backupURL)
        #expect(try Data(contentsOf: backupURL) == original)
        let stored = try store.read(at: config)
        #expect(stored["notify"] as? [String] == ["keep-me"])
        #expect(stored["custom"] as? Bool == true)
        #expect(stored["hooks"] != nil)
    }

    @Test func malformedJSONIsRejectedWithoutChangingOrBackingUpFile() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let config = root.appendingPathComponent("hooks.json")
        let backups = root.appendingPathComponent("backups")
        let malformed = Data("{not-json".utf8)
        try malformed.write(to: config)
        let store = HookConfigFileStore()

        #expect(throws: HookConfigFileStoreError.self) {
            try store.mutate(
                at: config,
                backupDirectory: backups,
                backupName: "hooks.json"
            ) { ($0, true) }
        }
        #expect(try Data(contentsOf: config) == malformed)
        #expect(!FileManager.default.fileExists(atPath: backups.path))
    }

    @Test func unchangedMutationDoesNotWriteOrCreateBackup() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let config = root.appendingPathComponent("hooks.json")
        let backups = root.appendingPathComponent("backups")
        let original = Data(#"{"custom":true}"#.utf8)
        try original.write(to: config)
        let store = HookConfigFileStore()

        let result = try store.mutate(
            at: config,
            backupDirectory: backups,
            backupName: "hooks.json"
        ) { ($0, false) }

        #expect(!result.changed)
        #expect(result.backupURL == nil)
        #expect(try Data(contentsOf: config) == original)
        #expect(!FileManager.default.fileExists(atPath: backups.path))
    }

    @Test func agentOperationsCaptureFailuresIndependently() {
        let report = HookAgentOperationReport.run(
            claude: { true },
            codex: { throw CocoaError(.fileReadCorruptFile) }
        )

        #expect(report.claude == .changed)
        guard case .failed = report.codex else {
            Issue.record("Codex avrebbe dovuto fallire indipendentemente")
            return
        }
        #expect(report.anyChanged)
        #expect(report.hasFailures)
    }
}
