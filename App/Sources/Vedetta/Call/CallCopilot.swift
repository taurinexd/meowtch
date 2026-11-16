import Combine
import Foundation
import VedettaKit

/// The quick lane: watches the live transcript, lets `AnswerTrigger` decide
/// when the client asked something, and streams one answer at a time from
/// the call's `claude` session. Runs only while listening with suggestions
/// turned on; turning them off is the kill-switch.
@MainActor
final class CallCopilot: ObservableObject {
    static let shared = CallCopilot()
    /// Buffer RMS above which a channel counts as speaking.
    static let speechRMS = 0.02
    private static let tickInterval: Duration = .milliseconds(250)
    private static let recentLines = 8

    @Published private(set) var isActive = false
    @Published private(set) var question: String?
    @Published private(set) var answer = ""
    @Published private(set) var isStreaming = false
    @Published private(set) var elapsed: TimeInterval = 0
    @Published private(set) var outputTokens = 0
    @Published private(set) var callCostUSD = 0.0
    @Published private(set) var engineProblem: String?
    /// What the quick answer asked to verify; for the deep lane (later).
    private(set) var verifyHint: String?
    private(set) var metrics = CallMetrics()

    private struct Ask: Sendable {
        let question: String
        let decidedAt: Date
    }

    private var engine: ClaudeCallEngine?
    private var hotKey: CallHotKey?
    private var ticker: Task<Void, Never>?
    private var turns = CallTurns()
    private var answered: [String] = []
    private var queue = LatestOnlyQueue<Ask>()
    private var raw = ""
    private var startedAt: Date?
    private var decidedAt: Date?
    private var defaultsObserver: AnyCancellable?

    var isHotKeyRegistered: Bool { hotKey?.isRegistered ?? false }

    static var isEnabled: Bool {
        UserDefaults.standard.bool(forKey: SettingsKey.callSuggestionsEnabled)
    }

    private init() {
        defaultsObserver = NotificationCenter.default
            .publisher(for: UserDefaults.didChangeNotification)
            .receive(on: DispatchQueue.main)
            .sink { _ in
                MainActor.assumeIsolated {
                    let copilot = CallCopilot.shared
                    if !Self.isEnabled, copilot.isActive {
                        copilot.stop()
                    } else if Self.isEnabled, !copilot.isActive, CallSession.shared.isListening {
                        copilot.start()
                    }
                }
            }
    }

    func setEnabled(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: SettingsKey.callSuggestionsEnabled)
    }

    func start() {
        guard Self.isEnabled, CallSession.shared.isListening, !isActive else { return }
        isActive = true
        resetCall()
        turns.consumeAll(in: CallSession.shared.transcript)  // earlier talk is not a question

        let engine = ClaudeCallEngine(
            onEvent: { event in Task { @MainActor in CallCopilot.shared.handle(event) } },
            onExit: { tail in Task { @MainActor in CallCopilot.shared.engineExited(tail) } }
        )
        self.engine = engine
        let folder = UserDefaults.standard.string(forKey: SettingsKey.callClientFolder).map { URL(fileURLWithPath: $0) }
        Task.detached {
            let context = ClaudeCallEngine.loadContext(clientFolder: folder)
            do {
                try engine.start(systemPrompt: CallCopilotPrompt.system(webgas: context.webgas, client: context.client))
            } catch CallEngineError.claudeNotFound {
                await MainActor.run { CallCopilot.shared.engineProblem = "Suggestions need the claude CLI, which is not installed on this Mac." }
            } catch {
                await MainActor.run { CallCopilot.shared.engineProblem = "Suggestions could not start: \(error.localizedDescription)" }
            }
        }

        let hotKey = CallHotKey { CallCopilot.shared.answerNow() }
        hotKey.register()
        self.hotKey = hotKey
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                self?.tick()
                try? await Task.sleep(for: Self.tickInterval)
            }
        }
    }

    func stop() {
        ticker?.cancel()
        ticker = nil
        hotKey?.unregister()
        hotKey = nil
        engine?.stop()
        engine = nil
        isActive = false
        resetCall()
    }

    /// ⌥ Space: answer the latest client words now, no heuristics.
    func answerNow() {
        guard isActive else { return }
        let transcript = CallSession.shared.transcript
        var text = turns.pending(in: transcript)
        if text.isEmpty { text = turns.lastClientText(in: transcript, lines: 2) }
        text = AnswerTrigger.questionText(text)
        guard !text.isEmpty else { return }
        turns.consumeAll(in: transcript)
        answered.append(text)
        metrics.recordOverride()
        submit(Ask(question: text, decidedAt: Date()))
    }

    private func resetCall() {
        question = nil
        answer = ""
        raw = ""
        isStreaming = false
        elapsed = 0
        outputTokens = 0
        callCostUSD = 0
        engineProblem = nil
        verifyHint = nil
        metrics = CallMetrics()
        turns = CallTurns()
        answered = []
        queue = LatestOnlyQueue()
        startedAt = nil
        decidedAt = nil
    }

    private func tick() {
        let now = Date()
        if isStreaming, let startedAt { elapsed = now.timeIntervalSince(startedAt) }
        let session = CallSession.shared
        let transcript = session.transcript
        let input = TriggerInput(
            pending: turns.pending(in: transcript), now: now,
            lastClientActivity: transcript.lines.last { $0.speaker == .client }?.updatedAt,
            lastClientSpeech: session.lastLoudClient,
            lastMeActivity: latest(transcript.lines.last { $0.speaker == .me }?.updatedAt, session.lastLoudMe),
            answered: answered
        )
        switch AnswerTrigger.decide(input) {
        case .wait:
            break
        case .consume:
            turns.consumeAll(in: transcript)
        case .fire(let question, let endpointAt):
            turns.consumeAll(in: transcript)
            answered.append(question)
            metrics.recordDecision(endpointToDecisionMs: Int(now.timeIntervalSince(endpointAt) * 1000))
            submit(Ask(question: question, decidedAt: now))
        }
    }

    private func latest(_ a: Date?, _ b: Date?) -> Date? {
        switch (a, b) {
        case let (a?, b?): max(a, b)
        case let (a?, nil): a
        case let (nil, b?): b
        case (nil, nil): nil
        }
    }

    private func submit(_ ask: Ask) {
        if let now = queue.submit(ask) { send(now) }
    }

    private func send(_ ask: Ask) {
        guard let engine else { return }
        question = ask.question
        answer = ""
        raw = ""
        isStreaming = true
        elapsed = 0
        outputTokens = 0
        startedAt = Date()
        decidedAt = ask.decidedAt
        let message = CallCopilotPrompt.userMessage(
            question: ask.question, recent: CallSession.shared.transcript.recent(Self.recentLines)
        )
        Task.detached { engine.send(message) }
    }

    private func handle(_ event: ClaudeStreamEvent) {
        guard isActive else { return }
        switch event {
        case .textDelta(let text):
            if raw.isEmpty, let decidedAt {
                metrics.recordFirstToken(decisionToFirstTokenMs: Int(Date().timeIntervalSince(decidedAt) * 1000))
            }
            raw += text
            answer = QuickAnswer.visible(raw)
            outputTokens = raw.count / 4
        case .result(let result):
            if result.isError {
                engineProblem = "Suggestions stopped: Claude returned an error. The next question retries."
            } else {
                engineProblem = nil
                let final = result.text.isEmpty ? raw : result.text
                answer = QuickAnswer.visible(final)
                verifyHint = QuickAnswer.verify(final)
                outputTokens = result.outputTokens
            }
            callCostUSD += result.costUSD
            finishAnswer()
        case .other:
            break
        }
    }

    private func engineExited(_ tail: String) {
        guard isActive else { return }
        let reason = tail.split(separator: "\n").last.map { String($0).trimmingCharacters(in: .whitespaces) }
        engineProblem = "Suggestions stopped: \(reason?.isEmpty == false ? reason! : "claude exited"). The next question restarts them."
        finishAnswer()
    }

    private func finishAnswer() {
        isStreaming = false
        if let startedAt { elapsed = Date().timeIntervalSince(startedAt) }
        if let next = queue.finish() { send(next) }
    }
}
