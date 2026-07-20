import AppKit
import Combine
import CoreGraphics
import Foundation
import VedettaKit

/// Live AskUserQuestion prompts shown in the notch. Unlike tool/plan
/// approvals (which block the bridge on an allow/deny decision), a question
/// is let through immediately with `allow` so its native picker appears in
/// the terminal; this store only mirrors it in the notch so the user can
/// answer from there (Step 2 synthesizes the keystrokes). It clears when
/// the tool completes (PostToolUse) or the turn moves on.
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

    @Published private(set) var live: [Live] = []

    func present(sessionId: String, questions: [Question]) {
        live.removeAll { $0.sessionId == sessionId }
        live.append(Live(id: sessionId, sessionId: sessionId, questions: questions))
    }

    func dismiss(sessionId: String) {
        live.removeAll { $0.sessionId == sessionId }
        selections[sessionId] = nil
    }

    func first(for sessionId: String) -> Live? {
        live.first { $0.sessionId == sessionId }
    }

    // MARK: - Accumulated selections (multiSelect / multi-question)

    /// Chosen option indices, keyed by session then question index. A
    /// single-select question keeps one index; a multiSelect one keeps many.
    @Published private(set) var selections: [String: [Int: Set<Int>]] = [:]

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

    /// Answers all questions by INJECTING the picker's keys straight into
    /// the terminal's stdin via the companion extension (terminal.sendText):
    /// real input injection, not synthesized global keystrokes — atomic (one
    /// write, can't be interrupted mid-sequence) and needing no window focus
    /// (the URI opens with activates=false). For each question it navigates
    /// to the chosen option(s) — arrows, Space-toggling each pick of a
    /// multiSelect one — then Return; between questions Tab moves to the next
    /// tab, and a final Return confirms the Submit tab.
    func submit(sessionId: String, session: AgentSession, terminal: TerminalInfo?) {
        guard let live = first(for: sessionId), canSubmit(sessionId: sessionId) else { return }
        let chosen = selections[sessionId] ?? [:]

        let down = "\u{1b}[B", enter = "\r", space = " ", tab = "\t"
        var keys = ""
        for (index, question) in live.questions.enumerated() {
            let picks = (chosen[index] ?? []).sorted()
            var cursor = 0
            if question.multiSelect {
                for pick in picks {
                    keys += String(repeating: down, count: max(0, pick - cursor))
                    cursor = pick
                    keys += space   // toggle this pick
                }
                keys += enter
            } else {
                keys += String(repeating: down, count: max(0, picks.first ?? 0))
                keys += enter
            }
            // Multi-question picker is tabbed: advance to the next question.
            if index < live.questions.count - 1 { keys += tab }
        }
        // A multi-question run lands on the Submit tab — confirm it.
        if live.questions.count > 1 { keys += enter }

        sendKeys(keys, session: session, terminal: terminal)
        dismiss(sessionId: sessionId)
    }

    /// Delivers the key string to the session's terminal via the companion
    /// extension's /answer URI, opened WITHOUT activating VS Code so the
    /// user's focus is never stolen. The extension writes it to the exact
    /// terminal's stdin (terminal.sendText).
    private func sendKeys(_ keys: String, session: AgentSession, terminal: TerminalInfo?) {
        guard let terminal else { return }
        let pids = terminal.pidChain ?? terminal.pid.map { [Int($0)] } ?? []
        guard !pids.isEmpty,
              let encodedKeys = keys.addingPercentEncoding(withAllowedCharacters: .alphanumerics),
              let workspace = session.directory.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed)
        else { return }
        let pidParams = pids.map { "pid=\($0)" }.joined(separator: "&")
        guard let url = URL(string:
            "vscode://vedetta.terminal-focus/answer?\(pidParams)&workspace=\(workspace)&keys=\(encodedKeys)")
        else { return }
        let config = NSWorkspace.OpenConfiguration()
        config.activates = false
        NSWorkspace.shared.open(url, configuration: config, completionHandler: nil)
    }
}
