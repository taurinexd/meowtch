import AppKit
import Combine
import Foundation

/// Live AskUserQuestion prompts shown in the notch. Like a plan approval,
/// the request BLOCKS the bridge: Vedetta holds the PermissionRequest hook
/// open, mirrors the question in the notch, and when the user answers there
/// it hands the answer back to Claude Code as DATA through the hook's
/// `decision.updatedInput.answers` — no terminal picker, no keystroke
/// injection, no focus. Claude Code then resolves the tool with those
/// answers exactly as if the native picker had been used. This is the same
/// channel the original uses (askUserQuestion routeNative).
@MainActor
final class QuestionStore: ObservableObject {
    static let shared = QuestionStore()

    struct Choice: Identifiable {
        let id = UUID()
        let label: String
        let detail: String?
    }

    struct Question: Identifiable {
        let id = UUID()
        let header: String?
        let prompt: String
        let multiSelect: Bool
        let choices: [Choice]
    }

    struct Live: Identifiable {
        let id: String        // one live prompt per session
        let sessionId: String
        let questions: [Question]
    }

    @Published private(set) var live: [Live] = [] {
        didSet { updateEnterMonitor() }
    }

    // MARK: - Enter-to-submit

    private var enterMonitor: Any?

    /// A global Return monitor, live only while a question is pending, so
    /// pressing Enter submits it just like clicking Invia — without the notch
    /// panel ever taking focus. It fires only once every question is answered,
    /// so a stray Enter elsewhere can't submit a half-filled prompt.
    private func updateEnterMonitor() {
        if live.isEmpty {
            if let monitor = enterMonitor { NSEvent.removeMonitor(monitor); enterMonitor = nil }
        } else if enterMonitor == nil {
            enterMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { event in
                guard event.keyCode == 36 || event.keyCode == 76 else { return }  // Return / keypad Enter
                Task { @MainActor in
                    let store = QuestionStore.shared
                    if let ready = store.live.first(where: { store.canSubmit(sessionId: $0.sessionId) }) {
                        store.submit(sessionId: ready.sessionId)
                    }
                }
            }
        }
    }

    /// Abandons the prompt: replies "allow" with empty answers, so Claude Code
    /// records "the user did not answer" and moves on.
    func skip(sessionId: String) { resolve(sessionId: sessionId, answers: [:]) }

    /// A suspended AskUserQuestion hook, keyed by session. It resumes with the
    /// answers record (question text → chosen label(s)) once the user answers
    /// from the notch, or nil when the question is abandoned — that nil lets
    /// the caller fall through to Claude Code's own picker. Holding this
    /// continuation is what keeps the bridge blocked meanwhile.
    private var continuations: [String: CheckedContinuation<[String: [String]]?, Never>] = [:]

    /// Presents the question in the notch and SUSPENDS until the user answers
    /// from there. Returns the answers record for `updatedInput.answers`
    /// (`{ question text: [chosen labels] }` — Claude Code joins the array
    /// comma-separated, so a single-select is just a one-element array), or
    /// nil if the question was abandoned before an answer.
    func awaitAnswer(sessionId: String, questions: [Question]) async -> [String: [String]]? {
        // A second prompt for the same session supersedes the first.
        continuations.removeValue(forKey: sessionId)?.resume(returning: nil)
        live.removeAll { $0.sessionId == sessionId }
        live.append(Live(id: sessionId, sessionId: sessionId, questions: questions))
        questionIndex[sessionId] = 0
        return await withCheckedContinuation { continuation in
            continuations[sessionId] = continuation
        }
    }

    func dismiss(sessionId: String) {
        live.removeAll { $0.sessionId == sessionId }
        selections[sessionId] = nil
        questionIndex[sessionId] = nil
        // Unblock a still-suspended hook (abandoned, e.g. the session ended):
        // resuming with nil lets the caller fall back to the native picker.
        continuations.removeValue(forKey: sessionId)?.resume(returning: nil)
    }

    func first(for sessionId: String) -> Live? {
        live.first { $0.sessionId == sessionId }
    }

    // MARK: - Accumulated selections (multiSelect / multi-question)

    /// Chosen option indices, keyed by session then question index. A
    /// single-select question keeps one index; a multiSelect one keeps many.
    @Published private(set) var selections: [String: [Int: Set<Int>]] = [:]

    /// The question the wizard is showing, per session. Multi-question prompts
    /// are stepped through one at a time (like the original's WizardQuestionView
    /// and the terminal's tabbed picker), not stacked.
    @Published private(set) var questionIndex: [String: Int] = [:]

    func currentIndex(sessionId: String) -> Int {
        let count = first(for: sessionId)?.questions.count ?? 1
        return min(max(0, questionIndex[sessionId] ?? 0), max(0, count - 1))
    }

    func setCurrentIndex(sessionId: String, _ index: Int) {
        questionIndex[sessionId] = index
    }

    func isAnswered(sessionId: String, questionIndex index: Int) -> Bool {
        !(selections[sessionId]?[index]?.isEmpty ?? true)
    }

    /// Jumps to the next still-unanswered question after the current one
    /// (wrapping once), so answering a single-select advances the wizard.
    func advanceToNextUnanswered(sessionId: String) {
        guard let live = first(for: sessionId), live.questions.count > 1 else { return }
        let current = currentIndex(sessionId: sessionId)
        let order = (1...live.questions.count).map { (current + $0) % live.questions.count }
        if let next = order.first(where: { isAnswered(sessionId: sessionId, questionIndex: $0) == false }) {
            questionIndex[sessionId] = next
        }
    }

    func isSelected(sessionId: String, questionIndex: Int, optionIndex: Int) -> Bool {
        selections[sessionId]?[questionIndex]?.contains(optionIndex) ?? false
    }

    func toggle(sessionId: String, questionIndex: Int, optionIndex: Int, multiSelect: Bool) {
        var forSession = selections[sessionId] ?? [:]
        var chosen = forSession[questionIndex] ?? []
        if multiSelect {
            if chosen.contains(optionIndex) { chosen.remove(optionIndex) } else { chosen.insert(optionIndex) }
        } else {
            chosen = [optionIndex]  // single-select replaces
        }
        forSession[questionIndex] = chosen
        selections[sessionId] = forSession
    }

    /// True once every question has at least one option chosen.
    func canSubmit(sessionId: String) -> Bool {
        guard let live = first(for: sessionId) else { return false }
        let chosen = selections[sessionId] ?? [:]
        return live.questions.indices.allSatisfy { !(chosen[$0]?.isEmpty ?? true) }
    }

    /// A single-select single question answers immediately on click; the
    /// rest accumulate and answer on an explicit submit.
    func isImmediate(sessionId: String) -> Bool {
        guard let live = first(for: sessionId) else { return false }
        return live.questions.count == 1 && !(live.questions.first?.multiSelect ?? false)
    }

    /// Parses the AskUserQuestion tool input into the display model.
    static func parse(_ input: [String: Any]?) -> [Question]? {
        guard let raw = input?["questions"] as? [[String: Any]], !raw.isEmpty else { return nil }
        let questions = raw.compactMap { entry -> Question? in
            guard let prompt = entry["question"] as? String else { return nil }
            let choices = (entry["options"] as? [[String: Any]])?.compactMap { option -> Choice? in
                guard let label = option["label"] as? String else { return nil }
                return Choice(label: label, detail: option["description"] as? String)
            } ?? []
            return Question(
                header: entry["header"] as? String,
                prompt: prompt,
                multiSelect: entry["multiSelect"] as? Bool ?? false,
                choices: choices
            )
        }
        return questions.isEmpty ? nil : questions
    }

    /// Resolves the suspended hook with the chosen answers. The record is
    /// keyed by question TEXT (what Claude Code expects) with the chosen
    /// option LABELS as an array — Claude Code joins the array comma-
    /// separated, so a single-select is a one-element array.
    func submit(sessionId: String) {
        guard let live = first(for: sessionId), canSubmit(sessionId: sessionId) else { return }
        let chosen = selections[sessionId] ?? [:]

        var answers: [String: [String]] = [:]
        for (index, question) in live.questions.enumerated() {
            let labels = (chosen[index] ?? []).sorted().compactMap { optionIndex -> String? in
                question.choices.indices.contains(optionIndex) ? question.choices[optionIndex].label : nil
            }
            answers[question.prompt] = labels
        }
        resolve(sessionId: sessionId, answers: answers)
    }

    /// Hands the answers to the suspended hook and clears the card. The
    /// notch state resets to running as the reducer's PostToolUse would.
    private func resolve(sessionId: String, answers: [String: [String]]?) {
        let continuation = continuations.removeValue(forKey: sessionId)
        live.removeAll { $0.sessionId == sessionId }
        selections[sessionId] = nil
        questionIndex[sessionId] = nil
        continuation?.resume(returning: answers)
    }
}
