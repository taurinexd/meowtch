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

    /// After answering, return focus to whatever app the user was in
    /// before the terminal was raised (the user's choice for Option 1).
    static var returnFocusAfterAnswer = true

    /// Answers all questions by driving the native picker: raise the exact
    /// terminal, then for each question in order navigate to the chosen
    /// option(s) — Space-toggling each pick for a multiSelect question, then
    /// Return to confirm and advance to the next — and finally return focus
    /// to where the user was. The picker starts each question on its first
    /// option; navigation is arrows + Space/Enter (measured on-screen).
    func submit(sessionId: String, session: AgentSession, terminal: TerminalInfo?) {
        guard let live = first(for: sessionId), canSubmit(sessionId: sessionId) else { return }
        let chosen = selections[sessionId] ?? [:]
        let plan: [(multiSelect: Bool, picks: [Int])] = live.questions.enumerated().map { index, question in
            (question.multiSelect, (chosen[index] ?? []).sorted())
        }
        let previous = NSWorkspace.shared.frontmostApplication
        let terminalBundle = terminal?.bundleIdentifier
        let returnFocus = Self.returnFocusAfterAnswer

        JumpService.jump(to: session, terminal: terminal)
        dismiss(sessionId: sessionId)

        Task { @MainActor in
            // Let the raise/URI settle so the picker is the key responder.
            try? await Task.sleep(for: .milliseconds(850))
            for question in plan {
                var cursor = 0
                if question.multiSelect {
                    for pick in question.picks {
                        try await moveDown(pick - cursor)
                        cursor = pick
                        TerminalKeys.tap(TerminalKeys.space)
                        try? await Task.sleep(for: .milliseconds(50))
                    }
                    TerminalKeys.tap(TerminalKeys.returnKey)
                } else {
                    try await moveDown((question.picks.first ?? 0) - cursor)
                    TerminalKeys.tap(TerminalKeys.returnKey)
                }
                // Give the next question's picker time to appear.
                try? await Task.sleep(for: .milliseconds(350))
            }
            if returnFocus, let previous, previous.bundleIdentifier != terminalBundle {
                try? await Task.sleep(for: .milliseconds(300))
                previous.activate()
            }
        }
    }

    private func moveDown(_ times: Int) async throws {
        for _ in 0..<max(0, times) {
            TerminalKeys.tap(TerminalKeys.downArrow)
            try await Task.sleep(for: .milliseconds(50))
        }
    }
}

/// Synthesizes the keystrokes that drive Claude Code's native option picker
/// in the focused terminal (arrow navigation + Return, keycodes measured
/// against the real picker layout).
@MainActor
enum TerminalKeys {
    static let downArrow: CGKeyCode = 125
    static let returnKey: CGKeyCode = 36
    static let space: CGKeyCode = 49

    static func tap(_ key: CGKeyCode) {
        let source = CGEventSource(stateID: .combinedSessionState)
        CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: true)?
            .post(tap: .cghidEventTap)
        CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: false)?
            .post(tap: .cghidEventTap)
    }
}
