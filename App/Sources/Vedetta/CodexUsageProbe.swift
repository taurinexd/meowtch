import Foundation

/// Reads Codex quota by driving `codex app-server` over its JSON-RPC (stdio,
/// newline-delimited): `initialize`, then `account/rateLimits/read`. The
/// reply's `rateLimits.{primary,secondary}` are `RateLimitWindow`s
/// (`usedPercent`, `resetsAt` epoch, `windowDurationMins`) — the same shape as
/// Claude's five_hour/seven_day, so they feed the same usage strip. The
/// original talks to the same app-server for its Codex usage.
///
/// One-shot per refresh: spawn, handshake, read, terminate — no warm
/// connection to babysit. Every failure mode is silent (no Codex window).
enum CodexUsageProbe {
    struct Snapshot: Sendable {
        var primary: UsageModel.Window?
        var secondary: UsageModel.Window?
    }

    static func probe() async -> Snapshot? {
        guard let codex = resolveCodexPath() else { return nil }
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                continuation.resume(returning: runProbe(codex: codex))
            }
        }
    }

    // MARK: - Locating the codex binary

    private static let cachedPath: String? = {
        let home = NSHomeDirectory()
        let fm = FileManager.default
        let candidates = [
            home + "/.npm-global/bin/codex",
            "/opt/homebrew/bin/codex",
            "/usr/local/bin/codex",
            home + "/.local/bin/codex",
            home + "/.bun/bin/codex",
        ]
        if let hit = candidates.first(where: { fm.isExecutableFile(atPath: $0) }) { return hit }
        // Fall back to the user's login PATH (nvm, volta, custom prefixes).
        let shell = Process()
        shell.executableURL = URL(fileURLWithPath: "/bin/zsh")
        shell.arguments = ["-lc", "command -v codex"]
        let out = Pipe()
        shell.standardOutput = out
        shell.standardError = Pipe()
        guard (try? shell.run()) != nil else { return nil }
        shell.waitUntilExit()
        let path = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (!path.isEmpty && fm.isExecutableFile(atPath: path)) ? path : nil
    }()

    private static func resolveCodexPath() -> String? { cachedPath }

    // MARK: - The probe

    private static func shellQuote(_ path: String) -> String {
        "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private static func runProbe(codex: String) -> Snapshot? {
        let process = Process()
        // A login shell so the `codex` node shebang finds `node` on PATH — a
        // GUI app's own PATH is minimal. `exec` replaces the shell with codex,
        // so the pipes and termination target codex directly.
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-lc", "exec \(shellQuote(codex)) app-server"]
        let stdinPipe = Pipe(), stdoutPipe = Pipe()
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = Pipe()  // swallow diagnostics
        guard (try? process.run()) != nil else { return nil }

        // A watchdog frees us from the server's endless run loop: terminating
        // it closes the pipe, so the read below sees EOF and stops.
        let watchdog = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + 8, execute: watchdog)
        defer {
            watchdog.cancel()
            if process.isRunning { process.terminate() }
        }

        let requests = [
            #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"clientInfo":{"name":"vedetta","version":"0.1.0"}}}"#,
            #"{"jsonrpc":"2.0","id":2,"method":"account/rateLimits/read","params":{}}"#,
        ].joined(separator: "\n") + "\n"
        stdinPipe.fileHandleForWriting.write(Data(requests.utf8))

        let handle = stdoutPipe.fileHandleForReading
        var buffer = Data()
        while true {
            let chunk = handle.availableData
            if chunk.isEmpty { break }  // EOF (watchdog fired or server exited)
            buffer.append(chunk)
            if let result = response(id: 2, in: buffer) {
                return snapshot(from: result)
            }
        }
        return nil
    }

    /// The `result` object of the newline-delimited JSON-RPC reply with the
    /// given id, or nil if it isn't in the buffer yet.
    private static func response(id: Int, in buffer: Data) -> [String: Any]? {
        for line in buffer.split(separator: 0x0A) {
            guard let object = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                  (object["id"] as? NSNumber)?.intValue == id else { continue }
            return object["result"] as? [String: Any]
        }
        return nil
    }

    private static func snapshot(from result: [String: Any]) -> Snapshot {
        let rateLimits = result["rateLimits"] as? [String: Any]
        return Snapshot(
            primary: window(rateLimits?["primary"] as? [String: Any]),
            secondary: window(rateLimits?["secondary"] as? [String: Any])
        )
    }

    private static func window(_ object: [String: Any]?) -> UsageModel.Window? {
        guard let object, let percent = (object["usedPercent"] as? NSNumber)?.intValue else { return nil }
        var resetsAt: Date?
        if let epoch = object["resetsAt"] as? NSNumber { resetsAt = Date(timeIntervalSince1970: epoch.doubleValue) }
        let minutes = (object["windowDurationMins"] as? NSNumber)?.intValue
        return UsageModel.Window(percent: percent, resetsAt: resetsAt, windowMinutes: minutes)
    }
}
