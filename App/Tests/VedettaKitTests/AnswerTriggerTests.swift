import Foundation
import Testing
@testable import VedettaKit

struct AnswerTriggerTests {
    private let now = Date(timeIntervalSinceReferenceDate: 1_000_000)

    private func input(_ pending: String, clientSilence: TimeInterval, meAgo: TimeInterval? = nil,
                       answered: [String] = []) -> TriggerInput {
        TriggerInput(
            pending: pending, now: now,
            lastClientActivity: now - clientSilence, lastClientSpeech: nil,
            lastMeActivity: meAgo.map { now - $0 },
            answered: answered
        )
    }

    private func fires(_ decision: TriggerDecision) -> Bool {
        if case .fire = decision { return true }
        return false
    }

    @Test func questionMarkFiresAfterShortSilence() {
        #expect(AnswerTrigger.decide(input("Quando consegnate il checkout?", clientSilence: 0.7))
            == .fire(question: "Quando consegnate il checkout?", endpointAt: now - 0.7))
        #expect(AnswerTrigger.decide(input("Quando consegnate il checkout?", clientSilence: 0.3)) == .wait)
    }

    @Test func markerWithoutQuestionMarkNeedsLongerSilence() {
        #expect(AnswerTrigger.decide(input("Quanto costa la migrazione", clientSilence: 0.8)) == .wait)
        #expect(fires(AnswerTrigger.decide(input("Quanto costa la migrazione", clientSilence: 1.1))))
    }

    @Test func modalOpenerCountsAsQuestion() {
        #expect(fires(AnswerTrigger.decide(input("Riuscite a farlo entro giugno", clientSilence: 1.1))))
        #expect(fires(AnswerTrigger.decide(input("È possibile spostare la consegna", clientSilence: 1.1))))
    }

    @Test func modalOpenerCountsInALaterSentence() {
        #expect(AnswerTrigger.decide(input("Il carrello misto funziona già. Riuscite a farlo entro giugno.", clientSilence: 1.1))
            == .fire(question: "Il carrello misto funziona già. Riuscite a farlo entro giugno.", endpointAt: now - 1.1))
        #expect(fires(AnswerTrigger.decide(input("Il nuovo tema è già pronto. Si può cambiare il colore dei pulsanti", clientSilence: 1.1))))
    }

    @Test func statementNeverFires() {
        #expect(AnswerTrigger.decide(input("Il carrello lo abbiamo provato ieri", clientSilence: 5)) == .wait)
    }

    @Test func truncatedSentenceWaits() {
        #expect(AnswerTrigger.decide(input("Quanto costa la migrazione e", clientSilence: 3)) == .wait)
        #expect(AnswerTrigger.decide(input("Come pensate di gestire il catalogo per", clientSilence: 3)) == .wait)
    }

    @Test func tooShortWaits() {
        #expect(AnswerTrigger.decide(input("Come?", clientSilence: 2)) == .wait)
    }

    @Test func meSpeakingConsumes() {
        #expect(AnswerTrigger.decide(input("Quando consegnate il checkout?", clientSilence: 2, meAgo: 0.5))
            == .consume(reason: .meSpeaking))
    }

    @Test func meAnsweringAfterTheQuestionConsumes() {
        // Matteo spoke after the client stopped, longer ago than the window.
        #expect(AnswerTrigger.decide(input("Quando consegnate il checkout?", clientSilence: 4, meAgo: 2))
            == .consume(reason: .meSpeaking))
    }

    @Test func meBeforeTheQuestionDoesNotSuppress() {
        #expect(fires(AnswerTrigger.decide(input("Quando consegnate il checkout?", clientSilence: 1, meAgo: 6))))
    }

    @Test func duplicateConsumes() {
        #expect(AnswerTrigger.decide(input("Quando consegnate il checkout?", clientSilence: 1,
                                           answered: ["quando consegnate il checkout"]))
            == .consume(reason: .duplicate))
    }

    @Test func nearDuplicateIsWordSetSimilarity() {
        #expect(AnswerTrigger.isNearDuplicate("Quando consegnate il checkout?", "quando consegnate il checkout"))
        #expect(!AnswerTrigger.isNearDuplicate("Quando consegnate il checkout?", "Quanto costa il checkout?"))
    }

    // Measured 2026-11-16: the transcript trails the audio by ~1 s and keeps
    // updating through short pauses; silence is read from the audio level.
    private func live(_ pending: String, audioSilence: TimeInterval, textSettled: TimeInterval) -> TriggerInput {
        TriggerInput(
            pending: pending, now: now,
            lastClientActivity: now - textSettled, lastClientSpeech: now - audioSilence,
            lastMeActivity: nil, answered: []
        )
    }

    @Test func audioSilenceWinsOverLateTranscriptUpdates() {
        #expect(fires(AnswerTrigger.decide(live("Come gestite le disiscrizioni dalla newsletter",
                                                audioSilence: 1.4, textSettled: 0.5))))
    }

    @Test func markerWaitsForTheTextToSettle() {
        #expect(AnswerTrigger.decide(live("Come gestite le disiscrizioni dalla neo",
                                          audioSilence: 1.2, textSettled: 0.1)) == .wait)
    }

    @Test func clientStillSpeakingWaitsEvenWithAQuestionMark() {
        #expect(AnswerTrigger.decide(live("Quanto costa una seconda lingua?",
                                          audioSilence: 0.1, textSettled: 2)) == .wait)
    }

    @Test func endpointIsWhenTheAudioWentQuiet() {
        #expect(AnswerTrigger.decide(live("Quando andate online col sito?", audioSilence: 0.8, textSettled: 0.2))
            == .fire(question: "Quando andate online col sito?", endpointAt: now - 0.8))
    }

    @Test func questionKeepsOnlyTheLastTwoSentences() {
        #expect(AnswerTrigger.questionText("Buongiorno. Allora, il sito va bene. Ma quando andate online? E con che costi?")
            == "Ma quando andate online? E con che costi?")
        #expect(AnswerTrigger.questionText("? Quanto costa la seconda lingua") == "Quanto costa la seconda lingua")
    }

    @Test func latestOnlyQueueKeepsOnlyTheLastWaiting() {
        var q = LatestOnlyQueue<String>()
        #expect(q.submit("a") == "a")
        #expect(q.submit("b") == nil)
        #expect(q.submit("c") == nil)
        #expect(q.finish() == "c")
        #expect(q.isBusy)
        #expect(q.finish() == nil)
        #expect(!q.isBusy)
    }
}
