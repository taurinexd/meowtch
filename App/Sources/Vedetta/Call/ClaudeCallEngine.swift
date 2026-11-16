import Foundation
import VedettaKit

enum CallEngineError: Error {
    case claudeNotFound
}

/// The quick lane's engine: one `claude -p` per call, fed one stream-json
/// message per question (spec 09-02 §5: a session per answer costs ~30×).
/// No tools, no MCP, no user settings, cwd in a neutral directory so no
/// AGENTS.md/CLAUDE.md is inherited.
final class ClaudeCallEngine: @unchecked Sendable {
    static let model = "haiku"

    private let onEvent: @Sendable (ClaudeStreamEvent) -> Void
    private let onExit: @Sendable (String) -> Void
    private let lock = NSLock()
    private var process: Process?
    private var stdin: FileHandle?
    private var systemPrompt = ""
    private var stdoutBuffer = Data()
    private var stderrTail = ""
    private var stopping = false

    init(onEvent: @escaping @Sendable (ClaudeStreamEvent) -> Void,
         onExit: @escaping @Sendable (String) -> Void) {
        self.onEvent = onEvent
        self.onExit = onExit
    }

    var isRunning: Bool {
        lock.withLock { process?.isRunning ?? false }
    }

    /// Neutral working directory, without memory files.
    static var workingDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".vedetta/call", isDirectory: true)
    }

    /// `~/.vedetta/call/webgas.md` and `<client>/.meowtch/client.md`, read
    /// only, when they exist.
    static func loadContext(clientFolder: URL?) -> (webgas: String?, client: String?) {
        let webgas = try? String(contentsOf: workingDirectory.appendingPathComponent("webgas.md"), encoding: .utf8)
        let client = clientFolder.flatMap {
            try? String(contentsOf: $0.appendingPathComponent(".meowtch/client.md"), encoding: .utf8)
        }
        return (webgas, client)
    }

    /// Launches the session. Blocks briefly while resolving `claude`.
    func start(systemPrompt: String) throws {
        guard let claude = ClaudeCLI.resolve() else { throw CallEngineError.claudeNotFound }
        signal(SIGPIPE, SIG_IGN)  // a write to a dead session must fail, not kill the app
        try FileManager.default.createDirectory(at: Self.workingDirectory, withIntermediateDirectories: true)

        let arguments = [
            "-p", "--input-format", "stream-json", "--output-format", "stream-json", "--verbose",
            "--include-partial-messages", "--tools", "", "--restricted", "--strict-mcp-config",
            "--no-session-persistence", "--model", Self.model, "--append-system-prompt", systemPrompt,
        ].map(ClaudeCLI.shellQuote).joined(separator: " ")

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ClaudeCLI.shellArguments(claude, arguments)
        process.currentDirectoryURL = Self.workingDirectory
        var environment = ProcessInfo.processInfo.environment
        environment.removeValue(forKey: "CLAUDE_CONFIG_DIR")  // default account (see ClaudeCLI.authStatus)
        process.environment = environment

        let input = Pipe(), output = Pipe(), errors = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = errors
        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            self?.receive(handle.availableData)
        }
        errors.fileHandleForReading.readabilityHandler = { [weak self] handle in
            guard let self else { return }
            let text = String(decoding: handle.availableData, as: UTF8.self)
            self.lock.withLock { self.stderrTail = String((self.stderrTail + text).suffix(300)) }
        }
        process.terminationHandler = { [weak self] _ in
            output.fileHandleForReading.readabilityHandler = nil
            errors.fileHandleForReading.readabilityHandler = nil
            guard let self else { return }
            let (expected, tail) = self.lock.withLock { () -> (Bool, String) in
                let expected = self.stopping
                self.process = nil
                self.stdin = nil
                return (expected, self.stderrTail)
            }
            if !expected { self.onExit(tail) }
        }

        try process.run()
        lock.withLock {
            self.process = process
            self.stdin = input.fileHandleForWriting
            self.systemPrompt = systemPrompt
            self.stdoutBuffer = Data()
            self.stderrTail = ""
            self.stopping = false
        }
    }

    /// Sends one question; restarts the session first if it died.
    func send(_ userMessage: String) {
        if !isRunning {
            let prompt = lock.withLock { systemPrompt }
            do {
                try start(systemPrompt: prompt)
            } catch {
                onExit("claude could not start")
                return
            }
        }
        let handle = lock.withLock { stdin }
        do {
            try handle?.write(contentsOf: Data(ClaudeStream.userLine(userMessage).utf8))
        } catch {
            onExit("claude stopped reading")
        }
    }

    func stop() {
        let process = lock.withLock { () -> Process? in
            stopping = true
            try? stdin?.close()
            stdin = nil
            return self.process
        }
        if let process, process.isRunning { process.terminate() }  // our own child only
    }

    private func receive(_ data: Data) {
        guard !data.isEmpty else { return }
        let lines = lock.withLock { () -> [String] in
            stdoutBuffer.append(data)
            var lines: [String] = []
            while let newline = stdoutBuffer.firstIndex(of: UInt8(ascii: "\n")) {
                lines.append(String(decoding: stdoutBuffer[stdoutBuffer.startIndex..<newline], as: UTF8.self))
                stdoutBuffer.removeSubrange(stdoutBuffer.startIndex...newline)
            }
            return lines
        }
        for line in lines {
            let event = ClaudeStream.parse(line: line)
            if event != .other { onEvent(event) }
        }
    }
}

/// Debug probe behind the `callAsk` socket command: one engine, its
/// streamed text and last result, readable without the UI.
enum CallAskProbe {
    nonisolated(unsafe) private static var engine: ClaudeCallEngine?
    nonisolated(unsafe) private static var log: [String: Any] = [:]
    private static let lock = NSLock()

    static func ask(_ question: String) {
        lock.withLock { log = ["text": "", "exits": (log["exits"] as? Int) ?? 0] }
        if engine == nil {
            engine = ClaudeCallEngine(
                onEvent: { event in
                    lock.withLock {
                        switch event {
                        case .textDelta(let text): log["text"] = ((log["text"] as? String) ?? "") + text
                        case .result(let result):
                            log["result"] = ["isError": result.isError, "costUSD": result.costUSD,
                                             "durationMs": result.durationMs, "outputTokens": result.outputTokens]
                        case .other: break
                        }
                    }
                },
                onExit: { tail in
                    lock.withLock {
                        log["exits"] = ((log["exits"] as? Int) ?? 0) + 1
                        log["exitTail"] = tail
                    }
                }
            )
            let context = ClaudeCallEngine.loadContext(clientFolder: nil)
            do {
                try engine?.start(systemPrompt: CallCopilotPrompt.system(webgas: context.webgas, client: context.client))
            } catch {
                lock.withLock { log["error"] = String(describing: error) }
                return
            }
        }
        engine?.send(CallCopilotPrompt.userMessage(question: question, recent: []))
    }

    static func state() -> [String: Any] {
        lock.withLock { log.merging(["running": engine?.isRunning ?? false]) { $1 } }
    }
}
