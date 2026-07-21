import Foundation
import VedettaKit

/// One warm stdio connection shared by quota, hook trust and policy reads.
/// Requests are multiplexed by JSON-RPC ID; failures keep callers on their
/// last-known-good state and trigger bounded restart backoff.
actor CodexAppServerClient {
    static let shared = CodexAppServerClient()

    enum ClientError: Error { case binaryUnavailable, startupBackoff, disconnected, timeout }

    private var process: Process?
    private var input: FileHandle?
    private var output: FileHandle?
    private var inbox = CodexRPCInbox()
    private var continuations: [Int: CheckedContinuation<JSONValue, Error>] = [:]
    private var nextID = 1
    private var initialized = false
    private var failureCount = 0
    private var retryAfter = Date.distantPast
    private var idleGeneration = 0
    private var rateAccumulator = CodexRateLimitAccumulator()
    private let codexHome: String?

    init(codexHome: String? = nil) {
        self.codexHome = codexHome
    }

    func rateLimits() async -> CodexRateLimitSnapshot? {
        do {
            let result = try await request(method: "account/rateLimits/read")
            _ = rateAccumulator.accept(result)
        } catch {}
        return rateAccumulator.snapshot
    }

    func hookTrust() async -> CodexHookTrustSnapshot {
        do {
            return CodexHookTrustSnapshot.parse(
                try await request(method: "hooks/list")
            )
        } catch {
            return CodexHookTrustSnapshot(state: .unavailable, handlers: [])
        }
    }

    func request(
        method: String,
        params: JSONValue = .object([:])
    ) async throws -> JSONValue {
        try await ensureStarted()
        let result = try await send(method: method, params: params)
        scheduleIdleShutdown()
        return result
    }

    func shutdown() {
        stopProcess()
    }

    private func ensureStarted() async throws {
        if initialized, process?.isRunning == true { return }
        guard Date() >= retryAfter else { throw ClientError.startupBackoff }
        guard let codex = Self.resolveCodexPath() else { throw ClientError.binaryUnavailable }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-lc", "exec \(Self.shellQuote(codex)) app-server"]
        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = Pipe()
        if let codexHome {
            var environment = ProcessInfo.processInfo.environment
            environment["CODEX_HOME"] = codexHome
            process.environment = environment
        }
        process.terminationHandler = { [weak self] _ in
            guard let self else { return }
            Task { await self.connectionEnded() }
        }
        do {
            try process.run()
        } catch {
            registerFailure()
            throw error
        }

        self.process = process
        input = stdinPipe.fileHandleForWriting
        output = stdoutPipe.fileHandleForReading
        output?.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard let self else { return }
            Task { await self.receive(data) }
        }

        do {
            _ = try await send(
                method: "initialize",
                params: .object([
                    "clientInfo": .object([
                        "name": .string("vedetta"),
                        "version": .string("0.1.0"),
                    ]),
                ])
            )
            initialized = true
            failureCount = 0
        } catch {
            stopProcess()
            registerFailure()
            throw error
        }
    }

    private func send(method: String, params: JSONValue) async throws -> JSONValue {
        guard process?.isRunning == true, let input else { throw ClientError.disconnected }
        let id = nextID
        nextID += 1
        let request: [String: Any] = [
            "jsonrpc": "2.0", "id": id, "method": method, "params": params.anyValue,
        ]
        var data = try JSONSerialization.data(withJSONObject: request)
        data.append(0x0A)

        return try await withCheckedThrowingContinuation { continuation in
            continuations[id] = continuation
            do {
                try input.write(contentsOf: data)
            } catch {
                continuations.removeValue(forKey: id)?.resume(throwing: error)
                return
            }
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(8))
                await self?.timeout(id: id)
            }
        }
    }

    private func receive(_ data: Data) {
        guard !data.isEmpty else {
            connectionEnded()
            return
        }
        inbox.ingest(data)
        for id in Array(continuations.keys) {
            if let result = inbox.takeResponse(id: id) {
                continuations.removeValue(forKey: id)?.resume(returning: result)
            }
        }
    }

    private func timeout(id: Int) {
        continuations.removeValue(forKey: id)?.resume(throwing: ClientError.timeout)
    }

    private func connectionEnded() {
        guard process != nil else { return }
        for continuation in continuations.values {
            continuation.resume(throwing: ClientError.disconnected)
        }
        continuations.removeAll()
        stopProcess()
        registerFailure()
    }

    private func scheduleIdleShutdown() {
        idleGeneration += 1
        let generation = idleGeneration
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(300))
            await self?.stopIfIdle(generation: generation)
        }
    }

    private func stopIfIdle(generation: Int) {
        guard generation == idleGeneration, continuations.isEmpty else { return }
        stopProcess()
    }

    private func stopProcess() {
        output?.readabilityHandler = nil
        if process?.isRunning == true { process?.terminate() }
        process = nil
        input = nil
        output = nil
        initialized = false
        inbox = CodexRPCInbox()
    }

    private func registerFailure() {
        failureCount = min(failureCount + 1, 6)
        retryAfter = Date().addingTimeInterval(pow(2, Double(failureCount - 1)))
    }

    private static func resolveCodexPath() -> String? {
        let home = NSHomeDirectory()
        let candidates = [
            home + "/.npm-global/bin/codex", "/opt/homebrew/bin/codex",
            "/usr/local/bin/codex", home + "/.local/bin/codex", home + "/.bun/bin/codex",
        ]
        if let hit = candidates.first(where: FileManager.default.isExecutableFile(atPath:)) {
            return hit
        }
        let shell = Process()
        shell.executableURL = URL(fileURLWithPath: "/bin/zsh")
        shell.arguments = ["-lc", "command -v codex"]
        let output = Pipe()
        shell.standardOutput = output
        shell.standardError = Pipe()
        guard (try? shell.run()) != nil else { return nil }
        shell.waitUntilExit()
        let path = String(
            decoding: output.fileHandleForReading.readDataToEndOfFile(),
            as: UTF8.self
        ).trimmingCharacters(in: .whitespacesAndNewlines)
        return path.isEmpty ? nil : path
    }

    private static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
