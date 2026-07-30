import Foundation

/// Pure logic for the Remote Bridge: an optional, off-by-default feature that
/// mirrors pending questions and plan approvals to a user-configured local
/// command, and parses answers dropped into `~/.vedetta/run/remote-answers/`.
/// No network is involved: the notify command is a local executable the user
/// chooses (e.g. a Telegram forwarder), keeping the no-cloud contract intact.
public enum RemoteBridgeLogic {
    public struct QuestionSnapshot: Equatable {
        public let sessionId: String
        public let title: String
        public let options: [String]
        /// Only single-question, single-select prompts are remotely answerable
        /// in this version; others stay notch-only.
        public let eligible: Bool

        public init(sessionId: String, title: String, options: [String], eligible: Bool) {
            self.sessionId = sessionId
            self.title = title
            self.options = options
            self.eligible = eligible
        }
    }

    public struct PlanSnapshot: Equatable {
        public let id: Int
        public let sessionId: String
        public let title: String

        public init(id: Int, sessionId: String, title: String) {
            self.id = id
            self.sessionId = sessionId
            self.title = title
        }
    }

    public enum Event: Equatable {
        case newQuestion(id: String, title: String, options: [String], session: String)
        case resolvedQuestion(id: String)
        case newPlan(id: String, title: String, session: String)
        case resolvedPlan(id: String)
    }

    /// Diffs the live question set against the already-notified ids.
    public static func diffQuestions(
        known: Set<String>, live: [QuestionSnapshot]
    ) -> (events: [Event], known: Set<String>) {
        let eligible = live.filter(\.eligible)
        let current = Set(eligible.map(\.sessionId))
        var events: [Event] = []
        for snapshot in eligible where !known.contains(snapshot.sessionId) {
            events.append(.newQuestion(
                id: snapshot.sessionId, title: snapshot.title,
                options: snapshot.options, session: snapshot.sessionId
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
            events.append(.newPlan(id: "plan-\(plan.id)", title: plan.title, session: plan.sessionId))
        }
        for gone in known.subtracting(current).sorted() {
            events.append(.resolvedPlan(id: "plan-\(gone)"))
        }
        return (events, current)
    }

    /// JSON payload handed to the notify command on stdin.
    public static func payload(for event: Event) -> [String: Any] {
        switch event {
        case let .newQuestion(id, title, options, session):
            return ["event": "new", "id": id, "kind": "question",
                    "title": title, "options": options, "session": session]
        case let .resolvedQuestion(id):
            return ["event": "resolved", "id": id, "kind": "question", "title": ""]
        case let .newPlan(id, title, session):
            return ["event": "new", "id": id, "kind": "plan", "title": title, "session": session]
        case let .resolvedPlan(id):
            return ["event": "resolved", "id": id, "kind": "plan", "title": ""]
        }
    }

    public enum Answer: Equatable {
        case question(sessionId: String, choice: Int)
        case plan(id: Int, allow: Bool)
    }

    /// Parses a remote answer file. Question: `{"id": "<sessionId>", "choice": n}`
    /// (1-based). Plan: `{"id": "plan-<n>", "decision": "approve"|"reject"}`.
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
        return .question(sessionId: id, choice: choice)
    }
}
