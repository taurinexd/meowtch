import Foundation
import Testing
@testable import VedettaKit

struct SessionTasksFreshnessTests {
    @Test func abandonmentFollowsTheCurrentRunBoundary() {
        let runStart = Date(timeIntervalSince1970: 2_000)
        // Files touched before the run started → a closed run's leftovers.
        #expect(SessionTasks.isAbandoned(
            latestModification: Date(timeIntervalSince1970: 1_000),
            runStartedAt: runStart
        ))
        // Touched during the current run → live list.
        #expect(!SessionTasks.isAbandoned(
            latestModification: Date(timeIntervalSince1970: 3_000),
            runStartedAt: runStart
        ))
        // Known run but no files at all → nothing to show.
        #expect(SessionTasks.isAbandoned(latestModification: nil, runStartedAt: runStart))
        // Unknown run start (adopted session) → keep whatever exists.
        #expect(!SessionTasks.isAbandoned(
            latestModification: Date(timeIntervalSince1970: 1_000),
            runStartedAt: nil
        ))
    }

    @Test func latestModificationTracksTheNewestTaskFile() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("vedetta-tasks-\(UUID().uuidString)")
        let dir = base.appendingPathComponent("session-1")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }

        let old = dir.appendingPathComponent("1.json")
        let new = dir.appendingPathComponent("2.json")
        try Data(#"{"subject":"a"}"#.utf8).write(to: old)
        try Data(#"{"subject":"b"}"#.utf8).write(to: new)
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 1_000)], ofItemAtPath: old.path
        )
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 5_000)], ofItemAtPath: new.path
        )
        // Hidden bookkeeping files (.highwatermark, .lock) never count.
        try Data("9".utf8).write(to: dir.appendingPathComponent(".highwatermark"))

        let latest = SessionTasks.latestModification(
            sessionId: "session-1", baseDir: base.path
        )
        #expect(latest == Date(timeIntervalSince1970: 5_000))
        #expect(SessionTasks.latestModification(
            sessionId: "missing", baseDir: base.path
        ) == nil)
    }
}
