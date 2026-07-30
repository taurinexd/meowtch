import Combine
import Foundation
import VedettaKit

/// Remote Bridge — optional, off by default. Mirrors pending questions and
/// plan approvals to a user-configured LOCAL command (stdin JSON), and applies
/// answers dropped into `~/.vedetta/run/remote-answers/` exactly as if they
/// were clicked in the notch. Vedetta stays the single arbiter: whichever
/// surface answers first wins, and the other side receives a `resolved` event.
///
/// Enable with:
///   defaults write app.vedetta.macos remoteBridgeCommand '/path/to/notifier'
/// Disable by removing the key. No network is involved on Vedetta's side.
@MainActor
final class RemoteBridge {
    static let shared = RemoteBridge()

    private var cancellables: Set<AnyCancellable> = []
    private var knownQuestions: Set<String> = []
    private var knownPlans: Set<Int> = []
    private var watcher: DispatchSourceFileSystemObject?
    private var watchedFd: Int32 = -1

    static var notifyCommand: String? {
        let value = UserDefaults.standard.string(forKey: "remoteBridgeCommand")
        return (value?.isEmpty ?? true) ? nil : value
    }

    static var answersDirectory: String { NSHomeDirectory() + "/.vedetta/run/remote-answers" }

    func start() {
        guard RemoteBridge.notifyCommand != nil, cancellables.isEmpty else { return }
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

    // MARK: - Outbound (notify)

    private func syncQuestions(_ live: [QuestionStore.Live]) {
        let snapshots = live.map { entry -> RemoteBridgeLogic.QuestionSnapshot in
            let first = entry.questions.first
            return RemoteBridgeLogic.QuestionSnapshot(
                sessionId: entry.sessionId,
                title: first?.prompt ?? "",
                options: first?.choices.map(\.label) ?? [],
                eligible: entry.questions.count == 1 && !(first?.multiSelect ?? true)
            )
        }
        let (events, known) = RemoteBridgeLogic.diffQuestions(known: knownQuestions, live: snapshots)
        knownQuestions = known
        events.forEach(notify)
    }

    private func syncPlans(_ pending: [ApprovalCenter.Pending]) {
        let snapshots = pending.compactMap { item -> RemoteBridgeLogic.PlanSnapshot? in
            guard case .plan = item.kind else { return nil }
            return RemoteBridgeLogic.PlanSnapshot(
                id: item.id, sessionId: item.sessionId,
                title: item.toolDetail ?? item.toolName
            )
        }
        let (events, known) = RemoteBridgeLogic.diffPlans(known: knownPlans, pending: snapshots)
        knownPlans = known
        events.forEach(notify)
    }

    private func notify(_ event: RemoteBridgeLogic.Event) {
        guard let command = RemoteBridge.notifyCommand,
              let data = try? JSONSerialization.data(withJSONObject: RemoteBridgeLogic.payload(for: event))
        else { return }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", command]
        let stdin = Pipe()
        process.standardInput = stdin
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            stdin.fileHandleForWriting.write(data)
            stdin.fileHandleForWriting.closeFile()
            log("notify sent: \(RemoteBridgeLogic.payload(for: event)["event"] ?? "?") \(RemoteBridgeLogic.payload(for: event)["id"] ?? "?")")
        } catch {
            log("notify failed: \(error)")
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
        source.setEventHandler { [weak self] in
            Task { @MainActor in self?.drainAnswers(applyStale: true) }
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
        case let .question(sessionId, choice):
            let store = QuestionStore.shared
            guard let live = store.first(for: sessionId),
                  live.questions.count == 1,
                  let question = live.questions.first,
                  !question.multiSelect,
                  question.choices.indices.contains(choice - 1) else {
                log("stale or invalid question answer for \(sessionId)")
                return
            }
            store.toggle(sessionId: sessionId, questionIndex: 0, optionIndex: choice - 1, multiSelect: false)
            store.submit(sessionId: sessionId)
            log("applied remote answer for question \(sessionId): option \(choice)")
        case let .plan(id, allow):
            ApprovalCenter.shared.decide(id: id, allow: allow)
            log("applied remote decision for plan-\(id): \(allow ? "approve" : "reject")")
        }
    }

    private func log(_ message: String) {
        let path = NSHomeDirectory() + "/.vedetta/run/remote-bridge.log"
        let line = "\(ISO8601DateFormatter().string(from: Date())) \(message)\n"
        if let handle = FileHandle(forWritingAtPath: path) {
            handle.seekToEndOfFile()
            handle.write(Data(line.utf8))
            handle.closeFile()
        } else {
            try? line.write(toFile: path, atomically: true, encoding: .utf8)
        }
    }
}
