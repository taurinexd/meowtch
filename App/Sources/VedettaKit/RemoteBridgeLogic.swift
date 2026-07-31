import CryptoKit
import Foundation

/// Pure logic for the Remote Bridge: an optional, off-by-default feature that
/// mirrors pending questions and plan approvals to a user-configured local
/// command, and parses answers dropped into `~/.vedetta/run/remote-answers/`.
/// No network is involved: the notify command is a local executable the user
/// chooses (e.g. a Telegram forwarder), keeping the no-cloud contract intact.
public enum RemoteBridgeLogic {
    /// How much of a plan travels to the remote surface. Telegram's rich
    /// messages (Bot API 10.1) hold 32k with a "Show more" fold at ~8k, so
    /// the body stops at the fold: past it nobody reads anyway.
    public static let planBodyLimit = 8000

    /// Per-option description budget. AskUserQuestion descriptions can run
    /// long and a Telegram message caps at 4096 characters, so each one is
    /// condensed to a phrase-sized excerpt.
    public static let optionDetailLimit = 300

    /// A choice as it travels: the label is what you tap, the detail is the
    /// reason to tap it. Dropping the detail meant choosing blind from a
    /// phone, since AskUserQuestion usually puts the decisive part there.
    public struct Option: Equatable {
        public let label: String
        public let detail: String?

        public init(label: String, detail: String? = nil) {
            self.label = label
            self.detail = detail
        }
    }

    public struct QuestionSnapshot: Equatable {
        public let sessionId: String
        /// Human-readable "which window is this?" — see `sessionLabel`.
        public let label: String
        public let title: String
        public let options: [Option]
        /// Only single-question, single-select prompts are remotely answerable
        /// in this version; others stay notch-only.
        public let eligible: Bool

        public init(
            sessionId: String, label: String, title: String,
            options: [Option], eligible: Bool
        ) {
            self.sessionId = sessionId
            self.label = label
            self.title = title
            self.options = options
            self.eligible = eligible
        }

        public var remoteId: String {
            questionId(sessionId: sessionId, prompt: title, options: options)
        }
    }

    public struct PlanSnapshot: Equatable {
        public let id: Int
        public let sessionId: String
        public let label: String
        public let markdown: String

        public init(id: Int, sessionId: String, label: String, markdown: String) {
            self.id = id
            self.sessionId = sessionId
            self.label = label
            self.markdown = markdown
        }
    }

    public enum Event: Equatable {
        case newQuestion(id: String, title: String, options: [Option],
                         session: String, sessionId: String)
        case resolvedQuestion(id: String)
        case newPlan(id: String, title: String, body: String,
                     session: String, sessionId: String)
        case resolvedPlan(id: String)
    }

    // MARK: - Which window is this?

    /// A remote prompt is useless if you cannot tell which of five open
    /// sessions is asking. Project folder, then the session's own name —
    /// that pair is what tells two windows apart. The host app is left out
    /// on purpose: knowing it is VS Code narrows nothing down.
    public static func sessionLabel(
        directory: String?, title: String?, sessionId: String
    ) -> String {
        var parts: [String] = []
        if let directory, !directory.isEmpty {
            let name = (directory as NSString).lastPathComponent
            if !name.isEmpty, name != "/" { parts.append(name) }
        }
        let name = title.map { condense($0, limit: 80) } ?? ""
        if !name.isEmpty, !parts.contains(name) { parts.append(name) }
        // Better a raw id than nothing to go on.
        return parts.isEmpty ? sessionId : parts.joined(separator: " · ")
    }

    // MARK: - Question identity

    /// A remote answer travels through a human: it can come back minutes after
    /// the question was asked, by which time the session may be on a different
    /// prompt. The id therefore carries a digest of the exact prompt and
    /// options it was minted for, and `apply` refuses anything that no longer
    /// matches — a late tap is dropped instead of landing on the wrong
    /// question. The separator is `.` because a session id never contains one.
    public static func fingerprint(prompt: String, options: [Option]) -> String {
        // Descriptions count: two prompts can share labels and differ only in
        // what those labels mean.
        let material = ([prompt] + options.flatMap { [$0.label, $0.detail ?? ""] })
            .joined(separator: "\u{1F}")
        let digest = SHA256.hash(data: Data(material.utf8))
        return digest.prefix(4).map { String(format: "%02x", $0) }.joined()
    }

    public static func questionId(sessionId: String, prompt: String, options: [Option]) -> String {
        "\(sessionId).\(fingerprint(prompt: prompt, options: options))"
    }

    public static func split(questionId: String) -> (sessionId: String, fingerprint: String)? {
        let parts = questionId.split(separator: ".", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty else { return nil }
        return (String(parts[0]), String(parts[1]))
    }

    // MARK: - Plan presentation

    /// A plan reaches the hook as markdown; the tool input carries no summary,
    /// so without this the remote surface would only see the tool name and the
    /// human would be approving something they cannot read.
    public static func planTitle(from markdown: String) -> String {
        let blocks = PlanMarkdown.blocks(from: markdown)
        for block in blocks {
            switch block {
            case let .heading(_, text): return condense(text)
            case let .paragraph(text), let .quote(text): return condense(text)
            case let .bullet(_, text), let .ordered(_, _, text): return condense(text)
            case .code, .divider: continue
            }
        }
        return "Plan review"
    }

    public static func planBody(from markdown: String, limit: Int = planBodyLimit) -> String {
        let trimmed = markdown.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > limit else { return trimmed }
        let head = trimmed.prefix(limit)
        // Cut on the last line break so the tail isn't a half-written bullet.
        let cut = head.lastIndex(of: "\n").map { head[..<$0] } ?? head
        return cut.trimmingCharacters(in: .whitespacesAndNewlines) + "\n…"
    }

    private static func condense(_ text: String, limit: Int = 120) -> String {
        let flat = text.split(whereSeparator: \.isNewline).joined(separator: " ")
            .trimmingCharacters(in: .whitespaces)
        guard flat.count > limit else { return flat }
        return flat.prefix(limit).trimmingCharacters(in: .whitespaces) + "…"
    }

    // MARK: - Diffing

    /// Diffs the live question set against the already-notified ids. Because
    /// the id is content-derived, a session that replaces one prompt with
    /// another in the same tick resolves the old id and announces the new one.
    public static func diffQuestions(
        known: Set<String>, live: [QuestionSnapshot]
    ) -> (events: [Event], known: Set<String>) {
        let eligible = live.filter(\.eligible)
        let current = Set(eligible.map(\.remoteId))
        var events: [Event] = []
        for snapshot in eligible where !known.contains(snapshot.remoteId) {
            events.append(.newQuestion(
                id: snapshot.remoteId, title: snapshot.title,
                options: snapshot.options, session: snapshot.label,
                sessionId: snapshot.sessionId
            ))
        }
        for gone in known.subtracting(current).sorted() {
            events.append(.resolvedQuestion(id: gone))
        }
        return (events, current)
    }

    /// Diffs pending plan approvals against the already-notified ids.
    public static func diffPlans(
        known: Set<Int>, pending: [PlanSnapshot]
    ) -> (events: [Event], known: Set<Int>) {
        let current = Set(pending.map(\.id))
        var events: [Event] = []
        for plan in pending where !known.contains(plan.id) {
            events.append(.newPlan(
                id: "plan-\(plan.id)",
                title: planTitle(from: plan.markdown),
                body: planBody(from: plan.markdown),
                session: plan.label,
                sessionId: plan.sessionId
            ))
        }
        for gone in known.subtracting(current).sorted() {
            events.append(.resolvedPlan(id: "plan-\(gone)"))
        }
        return (events, current)
    }

    /// JSON payload handed to the notify command on stdin.
    public static func payload(for event: Event) -> [String: Any] {
        switch event {
        case let .newQuestion(id, title, options, session, sessionId):
            // Options travel as objects; a receiver that only reads `label`
            // keeps working, which is what made this extension safe to ship.
            let encoded = options.map { option -> [String: Any] in
                var entry: [String: Any] = ["label": option.label]
                if let detail = option.detail, !detail.isEmpty {
                    entry["detail"] = condense(detail, limit: optionDetailLimit)
                }
                return entry
            }
            return ["event": "new", "id": id, "kind": "question",
                    "title": title, "options": encoded,
                    "session": session, "sessionId": sessionId]
        case let .resolvedQuestion(id):
            return ["event": "resolved", "id": id, "kind": "question", "title": ""]
        case let .newPlan(id, title, body, session, sessionId):
            return ["event": "new", "id": id, "kind": "plan",
                    "title": title, "body": body,
                    "session": session, "sessionId": sessionId]
        case let .resolvedPlan(id):
            return ["event": "resolved", "id": id, "kind": "plan", "title": ""]
        }
    }

    public enum Answer: Equatable {
        case question(id: String, choice: Int)
        case plan(id: Int, allow: Bool)
    }

    /// Parses a remote answer file. Question: `{"id": "<session>.<digest>",
    /// "choice": n}` (1-based). Plan: `{"id": "plan-<n>", "decision":
    /// "approve"|"reject"}`. The file must be written atomically (write to a
    /// dot-prefixed temp name, then rename) — a `.json` that fails to parse is
    /// discarded, not retried.
    public static func parseAnswer(_ data: Data) -> Answer? {
        guard let raw = try? JSONSerialization.jsonObject(with: data),
              let object = raw as? [String: Any],
              let id = object["id"] as? String else { return nil }
        if id.hasPrefix("plan-") {
            guard let planId = Int(id.dropFirst("plan-".count)),
                  let decision = object["decision"] as? String,
                  decision == "approve" || decision == "reject" else { return nil }
            return .plan(id: planId, allow: decision == "approve")
        }
        guard let choice = object["choice"] as? Int, choice >= 1 else { return nil }
        return .question(id: id, choice: choice)
    }
}
