import Foundation
import Testing
@testable import VedettaKit

@Suite("RemoteBridgeLogic")
struct RemoteBridgeLogicTests {
    private func question(
        _ sessionId: String = "s1", prompt: String = "Which one?",
        options: [String] = ["A", "B"], eligible: Bool = true
    ) -> RemoteBridgeLogic.QuestionSnapshot {
        RemoteBridgeLogic.QuestionSnapshot(
            sessionId: sessionId, title: prompt, options: options, eligible: eligible)
    }

    // MARK: - Identity

    @Test func questionIdCarriesAContentDigest() {
        let id = question().remoteId
        let parts = RemoteBridgeLogic.split(questionId: id)
        #expect(parts?.sessionId == "s1")
        #expect(parts?.fingerprint.count == 8)
        #expect(id == RemoteBridgeLogic.questionId(
            sessionId: "s1", prompt: "Which one?", options: ["A", "B"]))
    }

    @Test func fingerprintChangesWithPromptOrOptions() {
        let base = RemoteBridgeLogic.fingerprint(prompt: "Which one?", options: ["A", "B"])
        #expect(RemoteBridgeLogic.fingerprint(prompt: "Which two?", options: ["A", "B"]) != base)
        #expect(RemoteBridgeLogic.fingerprint(prompt: "Which one?", options: ["A", "C"]) != base)
        #expect(RemoteBridgeLogic.fingerprint(prompt: "Which one?", options: ["A", "B"]) == base)
    }

    @Test func splitRejectsAnIdWithoutADigest() {
        #expect(RemoteBridgeLogic.split(questionId: "s1") == nil)
        #expect(RemoteBridgeLogic.split(questionId: "s1.") == nil)
        #expect(RemoteBridgeLogic.split(questionId: ".abc") == nil)
    }

    // MARK: - Question diffing

    @Test func newEligibleQuestionEmitsEvent() {
        let snapshot = question()
        let (events, known) = RemoteBridgeLogic.diffQuestions(known: [], live: [snapshot])
        #expect(events == [.newQuestion(
            id: snapshot.remoteId, title: "Which one?", options: ["A", "B"], session: "s1")])
        #expect(known == [snapshot.remoteId])
    }

    @Test func ineligibleQuestionIsSkipped() {
        let (events, known) = RemoteBridgeLogic.diffQuestions(
            known: [], live: [question(options: ["A"], eligible: false)])
        #expect(events.isEmpty)
        #expect(known.isEmpty)
    }

    @Test func resolvedQuestionEmitsWhenGone() {
        let id = question().remoteId
        let (events, known) = RemoteBridgeLogic.diffQuestions(known: [id], live: [])
        #expect(events == [.resolvedQuestion(id: id)])
        #expect(known.isEmpty)
    }

    @Test func knownQuestionIsNotRenotified() {
        let snapshot = question()
        let (events, _) = RemoteBridgeLogic.diffQuestions(
            known: [snapshot.remoteId], live: [snapshot])
        #expect(events.isEmpty)
    }

    /// The case the session-keyed id used to miss: one prompt replaced by
    /// another between two ticks must retire the old id, not silently inherit
    /// it — otherwise a late remote tap would answer the wrong question.
    @Test func replacedPromptInSameSessionResolvesAndReannounces() {
        let first = question(prompt: "Ship it?")
        let second = question(prompt: "Roll back?")
        let (events, known) = RemoteBridgeLogic.diffQuestions(
            known: [first.remoteId], live: [second])
        #expect(events.contains(.newQuestion(
            id: second.remoteId, title: "Roll back?", options: ["A", "B"], session: "s1")))
        #expect(events.contains(.resolvedQuestion(id: first.remoteId)))
        #expect(known == [second.remoteId])
    }

    // MARK: - Plans

    @Test func planDiffEmitsPrefixedIdsAndReadableTitle() {
        let plan = RemoteBridgeLogic.PlanSnapshot(
            id: 7, sessionId: "s1", markdown: "# Fix the socket\n\nSteps follow.")
        let (events, known) = RemoteBridgeLogic.diffPlans(known: [], pending: [plan])
        #expect(events == [.newPlan(
            id: "plan-7", title: "Fix the socket",
            body: "# Fix the socket\n\nSteps follow.", session: "s1")])
        #expect(known == [7])
        let (resolved, empty) = RemoteBridgeLogic.diffPlans(known: known, pending: [])
        #expect(resolved == [.resolvedPlan(id: "plan-7")])
        #expect(empty.isEmpty)
    }

    @Test func planTitleFallsBackThroughTheFirstReadableBlock() {
        #expect(RemoteBridgeLogic.planTitle(from: "```\ncode\n```\n\nDo the thing.")
            == "Do the thing.")
        #expect(RemoteBridgeLogic.planTitle(from: "- first step\n- second step") == "first step")
        #expect(RemoteBridgeLogic.planTitle(from: "   ") == "Plan review")
        #expect(RemoteBridgeLogic.planTitle(from: "# \(String(repeating: "x", count: 200))")
            .count == 121)  // 120 + the ellipsis
    }

    @Test func planBodyIsTruncatedOnALineBoundary() {
        let long = (1...400).map { "line \($0)" }.joined(separator: "\n")
        let body = RemoteBridgeLogic.planBody(from: long, limit: 100)
        #expect(body.count <= 102)
        #expect(body.hasSuffix("\n…"))
        #expect(!body.contains("lin\n"))
        #expect(RemoteBridgeLogic.planBody(from: "short") == "short")
    }

    @Test func payloadShapes() {
        let question = RemoteBridgeLogic.payload(
            for: .newQuestion(id: "s1.abcd1234", title: "T", options: ["A"], session: "s1"))
        #expect(question["event"] as? String == "new")
        #expect(question["kind"] as? String == "question")
        #expect(question["options"] as? [String] == ["A"])
        let plan = RemoteBridgeLogic.payload(
            for: .newPlan(id: "plan-7", title: "Fix it", body: "# Fix it", session: "s1"))
        #expect(plan["title"] as? String == "Fix it")
        #expect(plan["body"] as? String == "# Fix it")
        let resolved = RemoteBridgeLogic.payload(for: .resolvedPlan(id: "plan-7"))
        #expect(resolved["event"] as? String == "resolved")
        #expect(resolved["kind"] as? String == "plan")
    }

    @Test func everyPayloadIsJSONSerialisable() {
        let events: [RemoteBridgeLogic.Event] = [
            .newQuestion(id: "s1.abcd1234", title: "T", options: ["A"], session: "s1"),
            .resolvedQuestion(id: "s1.abcd1234"),
            .newPlan(id: "plan-1", title: "T", body: "# T", session: "s1"),
            .resolvedPlan(id: "plan-1"),
        ]
        for event in events {
            #expect(JSONSerialization.isValidJSONObject(RemoteBridgeLogic.payload(for: event)))
        }
    }

    // MARK: - Answers

    @Test func parseQuestionAnswer() {
        let data = Data(#"{"id": "s1.abcd1234", "choice": 2}"#.utf8)
        #expect(RemoteBridgeLogic.parseAnswer(data) == .question(id: "s1.abcd1234", choice: 2))
    }

    @Test func parsePlanAnswer() {
        let approve = Data(#"{"id": "plan-7", "decision": "approve"}"#.utf8)
        #expect(RemoteBridgeLogic.parseAnswer(approve) == .plan(id: 7, allow: true))
        let reject = Data(#"{"id": "plan-7", "decision": "reject"}"#.utf8)
        #expect(RemoteBridgeLogic.parseAnswer(reject) == .plan(id: 7, allow: false))
    }

    @Test func parseRejectsGarbage() {
        #expect(RemoteBridgeLogic.parseAnswer(Data("nope".utf8)) == nil)
        #expect(RemoteBridgeLogic.parseAnswer(Data(#"{"id": "s1.a", "choice": 0}"#.utf8)) == nil)
        #expect(RemoteBridgeLogic.parseAnswer(Data(#"{"id": "plan-x", "decision": "approve"}"#.utf8)) == nil)
        #expect(RemoteBridgeLogic.parseAnswer(Data(#"{"id": "plan-7", "decision": "maybe"}"#.utf8)) == nil)
    }
}
