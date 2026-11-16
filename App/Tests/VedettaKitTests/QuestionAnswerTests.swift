import Testing
@testable import VedettaKit

struct QuestionAnswerTests {
    private let labels = ["Sì", "Solo (a)", "Lascia"]

    @Test func chosenLabelsInOptionOrder() {
        #expect(QuestionAnswer.values(labels: labels, selected: [2, 0], freeText: nil) == ["Sì", "Lascia"])
    }

    @Test func freeTextIsTrimmedAndAppended() {
        #expect(QuestionAnswer.values(labels: labels, selected: [], freeText: "  fai solo (b)\n") == ["fai solo (b)"])
        #expect(QuestionAnswer.values(labels: labels, selected: [1], freeText: "e avvisa") == ["Solo (a)", "e avvisa"])
    }

    @Test func blankFreeTextDoesNotAnswer() {
        #expect(QuestionAnswer.isAnswered(selected: [], freeText: "   ") == false)
        #expect(QuestionAnswer.isAnswered(selected: [], freeText: "x"))
        #expect(QuestionAnswer.isAnswered(selected: [0], freeText: nil))
        #expect(QuestionAnswer.values(labels: labels, selected: [9], freeText: nil).isEmpty)
    }
}
