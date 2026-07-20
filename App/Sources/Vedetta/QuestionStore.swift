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
    }

    func first(for sessionId: String) -> Live? {
        live.first { $0.sessionId == sessionId }
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

    /// Answers option `optionIndex` (0-based) of a single-select question by
    /// driving the native terminal picker: raise the session's terminal,
    /// then synthesize ↓ optionIndex times + Return (the picker starts on
    /// the first option; navigation is arrows+Enter, measured on-screen).
    func answer(
        sessionId: String,
        optionIndex: Int,
        session: AgentSession,
        terminal: TerminalInfo?
    ) {
        let previous = NSWorkspace.shared.frontmostApplication
        let terminalBundle = terminal?.bundleIdentifier
        let returnFocus = Self.returnFocusAfterAnswer
        // Bring the exact terminal to the front (raise + companion focus).
        JumpService.jump(to: session, terminal: terminal)
        Task { @MainActor in
            // Let the raise/URI settle so the picker is the key responder.
            try? await Task.sleep(for: .milliseconds(850))
            // Navigate to the option (picker starts on the first) and confirm,
            // spacing keys so the TUI processes each one.
            for _ in 0..<max(0, optionIndex) {
                TerminalKeys.tap(TerminalKeys.downArrow)
                try? await Task.sleep(for: .milliseconds(50))
            }
            TerminalKeys.tap(TerminalKeys.returnKey)
            // Return to where the user was, if requested.
            if returnFocus, let previous, previous.bundleIdentifier != terminalBundle {
                try? await Task.sleep(for: .milliseconds(300))
                previous.activate()
            }
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

    static func tap(_ key: CGKeyCode) {
        let source = CGEventSource(stateID: .combinedSessionState)
        CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: true)?
            .post(tap: .cghidEventTap)
        CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: false)?
            .post(tap: .cghidEventTap)
    }
}
