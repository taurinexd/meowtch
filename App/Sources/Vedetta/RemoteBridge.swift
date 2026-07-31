import Combine
import Foundation
import VedettaKit

/// Remote Bridge — optional, off by default. Mirrors pending questions and
/// plan approvals to a user-configured LOCAL command (stdin JSON), and applies
/// answers dropped into `~/.vedetta/run/remote-answers/` exactly as if they
/// were clicked in the notch. Vedetta stays the single arbiter: whichever
/// surface answers first wins, and the other side receives a `resolved` event.
///
/// Enable in Settings → Integrations, or with:
///   defaults write app.vedetta.macos remoteBridgeCommand '/path/to/notifier'
/// Clearing it disables the bridge; either way it takes effect immediately, no
/// relaunch. No network is involved on Vedetta's side — but the payload does
/// carry the question text, its options and the plan body to whatever command
/// is configured, so the command is as trusted as the terminal itself.
@MainActor
final class RemoteBridge {
    static let shared = RemoteBridge()

    private var cancellables: Set<AnyCancellable> = []
    private var configObserver: Set<AnyCancellable> = []
    private var knownQuestions: Set<String> = []
    private var knownPlans: Set<Int> = []
    private var watcher: DispatchSourceFileSystemObject?
    private var watchedFd: Int32 = -1
    private var activeCommand: String?

    /// Spawning the notifier is a fork+exec of a user command: off the main
    /// thread, so a slow interpreter can never stutter the notch. **Serial**,
    /// and each notifier is waited out before the next starts: a `resolved`
    /// overtaking its own `new` leaves an orphaned message on the remote
    /// surface that nothing will ever retract. Order beats latency here.
    private static let notifyQueue = DispatchQueue(label: "app.vedetta.remote-bridge.notify")

    /// A hung notifier must not hold the queue forever; past this it is
    /// terminated and the next event goes out.
    private static let notifyTimeout: TimeInterval = 30

    static let commandDefaultsKey = "remoteBridgeCommand"

    static var notifyCommand: String? {
        let value = UserDefaults.standard.string(forKey: commandDefaultsKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (value?.isEmpty ?? true) ? nil : value
    }

    static var answersDirectory: String { NSHomeDirectory() + "/.vedetta/run/remote-answers" }

    /// Called once at launch. The bridge follows the defaults key from there
    /// on, so turning it on or off takes effect at once — no relaunch.
    func begin() {
        NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)
            // Typing a path into the Settings field writes the key on every
            // keystroke; settle before acting on a half-written command.
            .debounce(for: .milliseconds(500), scheduler: RunLoop.main)
            .sink { [weak self] _ in
                Task { @MainActor in self?.refresh() }
            }
            .store(in: &configObserver)
        // That notification only fires for in-process writes (the Settings
        // field). A `defaults write` from a terminal never posts it, so poll
        // as well — reading one key is free next to being silently stuck on
        // the old configuration.
        Timer.publish(every: 5, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                Task { @MainActor in self?.refresh() }
            }
            .store(in: &configObserver)
        refresh()
    }

    private func refresh() {
        let command = RemoteBridge.notifyCommand
        guard command != activeCommand else { return }
        activeCommand = command
        if command == nil { stop() } else { start() }
    }

    private func start() {
        stop()
        try? FileManager.default.createDirectory(
            atPath: RemoteBridge.answersDirectory, withIntermediateDirectories: true)
        drainAnswers(applyStale: false)  // clear leftovers from a previous run

        QuestionStore.shared.$live
            .sink { [weak self] live in self?.syncQuestions(live) }
            .store(in: &cancellables)
        ApprovalCenter.shared.$pending
            .sink { [weak self] pending in self?.syncPlans(pending) }
            .store(in: &cancellables)
        startWatcher()
        log("remote bridge active; watching \(RemoteBridge.answersDirectory)")
    }

    private func stop() {
        guard !cancellables.isEmpty || watcher != nil else { return }
        cancellables.removeAll()
        watcher?.cancel()
        watcher = nil
        watchedFd = -1
        knownQuestions.removeAll()
        knownPlans.removeAll()
        log("remote bridge stopped")
    }

    // MARK: - Outbound (notify)

    /// "vedetta · Fix del bridge" — enough to know which of five open
    /// sessions is asking, from a phone.
    private func label(for sessionId: String) -> String {
        if let store = EventDispatcher.store {
            SessionBootstrap.refreshNameNow(for: sessionId, in: store)
        }
        let session = EventDispatcher.store?.sessions.first { $0.id == sessionId }
        return RemoteBridgeLogic.sessionLabel(
            directory: session?.directory, title: session?.title, sessionId: sessionId)
    }

    private func syncQuestions(_ live: [QuestionStore.Live]) {
        let snapshots = live.map { entry -> RemoteBridgeLogic.QuestionSnapshot in
            let first = entry.questions.first
            return RemoteBridgeLogic.QuestionSnapshot(
                sessionId: entry.sessionId,
                label: label(for: entry.sessionId),
                title: first?.prompt ?? "",
                options: first?.choices.map {
                    RemoteBridgeLogic.Option(label: $0.label, detail: $0.detail)
                } ?? [],
                eligible: entry.questions.count == 1 && !(first?.multiSelect ?? true)
            )
        }
        let (events, known) = RemoteBridgeLogic.diffQuestions(known: knownQuestions, live: snapshots)
        knownQuestions = known
        events.forEach(notify)
    }

    private func syncPlans(_ pending: [ApprovalCenter.Pending]) {
        let snapshots = pending.compactMap { item -> RemoteBridgeLogic.PlanSnapshot? in
            // The plan markdown is the only readable description there is: the
            // tool input carries no summary, so `toolDetail` is nil here.
            guard case .plan(let markdown) = item.kind else { return nil }
            return RemoteBridgeLogic.PlanSnapshot(
                id: item.id, sessionId: item.sessionId,
                label: label(for: item.sessionId), markdown: markdown)
        }
        let (events, known) = RemoteBridgeLogic.diffPlans(known: knownPlans, pending: snapshots)
        knownPlans = known
        events.forEach(notify)
    }

    private func notify(_ event: RemoteBridgeLogic.Event) {
        guard let command = RemoteBridge.notifyCommand else { return }
        let payload = RemoteBridgeLogic.payload(for: event)
        guard let data = try? JSONSerialization.data(withJSONObject: payload) else { return }
        let label = "\(payload["event"] ?? "?") \(payload["id"] ?? "?")"
        let timeout = RemoteBridge.notifyTimeout

        RemoteBridge.notifyQueue.async {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = ["-c", command]
            let stdin = Pipe()
            let stderr = Pipe()
            process.standardInput = stdin
            process.standardOutput = FileHandle.nullDevice
            process.standardError = stderr
            let finished = DispatchSemaphore(value: 0)
            process.terminationHandler = { _ in finished.signal() }
            var outcome: String
            var started = false
            do {
                try process.run()
                started = true
                // A notifier that dies before reading stdin (a broken shim, a
                // failing interpreter) leaves a broken pipe. SIGPIPE is
                // ignored process-wide (main.swift), so the non-throwing
                // FileHandle.write would raise an Objective-C exception Swift
                // cannot catch and abort the whole app: use the throwing one.
                try stdin.fileHandleForWriting.write(contentsOf: data)
                try? stdin.fileHandleForWriting.close()
                outcome = "notify sent: \(label)"
            } catch {
                try? stdin.fileHandleForWriting.close()
                outcome = "notify failed: \(label) — \(error.localizedDescription)"
            }
            // Handing the payload over is not the same as delivering it: a
            // notifier can accept the JSON and then refuse, or crash. Without
            // its exit code the log would claim success while nothing ever
            // reached the phone — exactly how a disabled gateway hid itself.
            if started {
                if finished.wait(timeout: .now() + timeout) == .timedOut {
                    process.terminate()
                    _ = finished.wait(timeout: .now() + 2)
                    outcome += " — timed out after \(Int(timeout))s"
                }
                // Read once it has exited: the pipe is at EOF, so no blocking.
                let complaint = String(
                    decoding: (try? stderr.fileHandleForReading.readToEnd()) ?? Data(), as: UTF8.self
                ).trimmingCharacters(in: .whitespacesAndNewlines)
                if process.terminationStatus != 0 {
                    outcome += " — command exited \(process.terminationStatus)"
                    if !complaint.isEmpty { outcome += ": \(complaint.prefix(400))" }
                }
            }
            Task { @MainActor in RemoteBridge.shared.log(outcome) }
        }
    }

    // MARK: - Inbound (answers)

    private func startWatcher() {
        watchedFd = open(RemoteBridge.answersDirectory, O_EVTONLY)
        guard watchedFd >= 0 else {
            log("cannot watch answers dir")
            return
        }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: watchedFd, eventMask: .write, queue: .main)
        source.setEventHandler {
            Task { @MainActor in RemoteBridge.shared.drainAnswers(applyStale: true) }
        }
        source.setCancelHandler { [fd = watchedFd] in close(fd) }
        source.resume()
        watcher = source
    }

    private func drainAnswers(applyStale: Bool) {
        let dir = RemoteBridge.answersDirectory
        let files = (try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []
        for name in files where name.hasSuffix(".json") {
            let path = dir + "/" + name
            defer { try? FileManager.default.removeItem(atPath: path) }
            guard applyStale,
                  let data = FileManager.default.contents(atPath: path),
                  let answer = RemoteBridgeLogic.parseAnswer(data) else { continue }
            apply(answer)
        }
    }

    private func apply(_ answer: RemoteBridgeLogic.Answer) {
        switch answer {
        case let .question(id, choice):
            // The digest in the id pins the answer to the exact prompt it was
            // sent for: a tap that arrives after the session moved on is
            // dropped rather than applied to whatever is live now.
            guard let (sessionId, fingerprint) = RemoteBridgeLogic.split(questionId: id) else {
                log("answer id without a digest: \(id)")
                return
            }
            let store = QuestionStore.shared
            guard let live = store.first(for: sessionId),
                  live.questions.count == 1,
                  let question = live.questions.first,
                  !question.multiSelect,
                  RemoteBridgeLogic.fingerprint(
                      prompt: question.prompt,
                      options: question.choices.map {
                          RemoteBridgeLogic.Option(label: $0.label, detail: $0.detail)
                      }
                  ) == fingerprint,
                  question.choices.indices.contains(choice - 1) else {
                log("stale or invalid question answer for \(id)")
                return
            }
            store.toggle(sessionId: sessionId, questionIndex: 0, optionIndex: choice - 1, multiSelect: false)
            store.submit(sessionId: sessionId)
            log("applied remote answer for question \(id): option \(choice)")
        case let .plan(id, allow):
            ApprovalCenter.shared.decide(id: id, allow: allow)
            log("applied remote decision for plan-\(id): \(allow ? "approve" : "reject")")
        }
    }

    // MARK: - Log

    private static let logSizeLimit = 256 * 1024

    private func log(_ message: String) {
        let path = NSHomeDirectory() + "/.vedetta/run/remote-bridge.log"
        rotateLogIfNeeded(at: path)
        let line = "\(ISO8601DateFormatter().string(from: Date())) \(message)\n"
        if let handle = FileHandle(forWritingAtPath: path) {
            handle.seekToEndOfFile()
            try? handle.write(contentsOf: Data(line.utf8))
            try? handle.close()
        } else {
            try? line.write(toFile: path, atomically: true, encoding: .utf8)
        }
    }

    /// One generation of history is plenty for a diagnostic log, and it keeps
    /// a long-lived bridge from quietly filling the disk.
    private func rotateLogIfNeeded(at path: String) {
        let attributes = try? FileManager.default.attributesOfItem(atPath: path)
        guard let size = attributes?[.size] as? Int, size > RemoteBridge.logSizeLimit else { return }
        let previous = path + ".1"
        try? FileManager.default.removeItem(atPath: previous)
        try? FileManager.default.moveItem(atPath: path, toPath: previous)
    }
}
