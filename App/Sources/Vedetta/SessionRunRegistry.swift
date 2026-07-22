import Foundation

/// When each Claude session's CURRENT run began (SessionStart with source
/// startup/resume). Persisted so the task-list freshness check survives app
/// restarts: without it, a restart would resurrect task lists that belong
/// to a closed run.
@MainActor
enum SessionRunRegistry {
    private static var path: String {
        NSHomeDirectory() + "/Library/Application Support/Vedetta/session-runs.json"
    }

    private static var cache: [String: TimeInterval] = load()
    /// Entries older than this are dropped on save (sessions gone for good).
    private static let retention: TimeInterval = 14 * 24 * 3600

    static func recordRunStart(sessionId: String, at date: Date) {
        cache[sessionId] = date.timeIntervalSince1970
        save()
    }

    static func runStart(for sessionId: String) -> Date? {
        cache[sessionId].map(Date.init(timeIntervalSince1970:))
    }

    private static func load() -> [String: TimeInterval] {
        guard let data = FileManager.default.contents(atPath: path),
              let map = try? JSONDecoder().decode([String: TimeInterval].self, from: data)
        else { return [:] }
        return map
    }

    private static func save() {
        let cutoff = Date().timeIntervalSince1970 - retention
        cache = cache.filter { $0.value > cutoff }
        let fm = FileManager.default
        try? fm.createDirectory(
            atPath: (path as NSString).deletingLastPathComponent,
            withIntermediateDirectories: true
        )
        if let data = try? JSONEncoder().encode(cache) {
            try? data.write(to: URL(fileURLWithPath: path), options: .atomic)
        }
    }
}
