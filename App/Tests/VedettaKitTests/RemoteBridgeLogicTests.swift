import Foundation
import Testing
@testable import VedettaKit

@Suite("RemoteBridgeLogic")
struct RemoteBridgeLogicTests {
    @Test func newEligibleQuestionEmitsEvent() {
        let snapshot = RemoteBridgeLogic.QuestionSnapshot(
            sessionId: "s1", title: "Which one?", options: ["A", "B"], eligible: true)
        let (events, known) = RemoteBridgeLogic.diffQuestions(known: [], live: [snapshot])
        #expect(events == [.newQuestion(id: "s1", title: "Which one?", options: ["A", "B"], session: "s1")])
        #expect(known == ["s1"])
    }

    @Test func ineligibleQuestionIsSkipped() {
        let snapshot = RemoteBridgeLogic.QuestionSnapshot(
            sessionId: "s1", title: "Multi?", options: ["A"], eligible: false)
        let (events, known) = RemoteBridgeLogic.diffQuestions(known: [], live: [snapshot])
        #expect(events.isEmpty)
        #expect(known.isEmpty)
    }

    @Test func resolvedQuestionEmitsWhenGone() {
        let (events, known) = RemoteBridgeLogic.diffQuestions(known: ["s1"], live: [])
        #expect(events == [.resolvedQuestion(id: "s1")])
        #expect(known.isEmpty)
    }

    @Test func knownQuestionIsNotRenotified() {
        let snapshot = RemoteBridgeLogic.QuestionSnapshot(
            sessionId: "s1", title: "Which one?", options: ["A"], eligible: true)
        let (events, _) = RemoteBridgeLogic.diffQuestions(known: ["s1"], live: [snapshot])
        #expect(events.isEmpty)
    }

    @Test func planDiffEmitsPrefixedIds() {
        let plan = RemoteBridgeLogic.PlanSnapshot(id: 7, sessionId: "s1", title: "Plan: fix")
        let (events, known) = RemoteBridgeLogic.diffPlans(known: [], pending: [plan])
        #expect(events == [.newPlan(id: "plan-7", title: "Plan: fix", session: "s1")])
        #expect(known == [7])
        let (resolved, empty) = RemoteBridgeLogic.diffPlans(known: known, pending: [])
        #expect(resolved == [.resolvedPlan(id: "plan-7")])
        #expect(empty.isEmpty)
    }

    @Test func payloadShapes() {
        let question = RemoteBridgeLogic.payload(
            for: .newQuestion(id: "s1", title: "T", options: ["A"], session: "s1"))
        #expect(question["event"] as? String == "new")
        #expect(question["kind"] as? String == "question")
        #expect(question["options"] as? [String] == ["A"])
        let plan = RemoteBridgeLogic.payload(for: .resolvedPlan(id: "plan-7"))
        #expect(plan["event"] as? String == "resolved")
        #expect(plan["kind"] as? String == "plan")
    }

    @Test func parseQuestionAnswer() {
        let data = Data(#"{"id": "s1", "choice": 2}"#.utf8)
        #expect(RemoteBridgeLogic.parseAnswer(data) == .question(sessionId: "s1", choice: 2))
    }

    @Test func parsePlanAnswer() {
        let approve = Data(#"{"id": "plan-7", "decision": "approve"}"#.utf8)
        #expect(RemoteBridgeLogic.parseAnswer(approve) == .plan(id: 7, allow: true))
        let reject = Data(#"{"id": "plan-7", "decision": "reject"}"#.utf8)
        #expect(RemoteBridgeLogic.parseAnswer(reject) == .plan(id: 7, allow: false))
    }

    @Test func parseRejectsGarbage() {
        #expect(RemoteBridgeLogic.parseAnswer(Data("nope".utf8)) == nil)
        #expect(RemoteBridgeLogic.parseAnswer(Data(#"{"id": "s1", "choice": 0}"#.utf8)) == nil)
        #expect(RemoteBridgeLogic.parseAnswer(Data(#"{"id": "plan-x", "decision": "approve"}"#.utf8)) == nil)
        #expect(RemoteBridgeLogic.parseAnswer(Data(#"{"id": "plan-7", "decision": "maybe"}"#.utf8)) == nil)
    }
}
