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

    @Test func explicitRequestCountsMidSentence() {
        // Real transcript shape: no «?», request after a lead-in.
        let text = "Ok, perfetto. E per il collegamento con il gestionale riuscite a sincronizzare anche le giacenze del magazzino."
        #expect(fires(AnswerTrigger.decide(input(text, clientSilence: 1.1))))
    }

    @Test func weakOpenerMidSentenceIsNotAQuestion() {
        #expect(AnswerTrigger.decide(input("Allora ok, hai ragione sul catalogo nuovo", clientSilence: 1.1)) == .wait)
        #expect(AnswerTrigger.decide(input("Va bene, ci sono già tutti i prodotti online", clientSilence: 1.1)) == .wait)
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
                                                audioSilence: 1.4, textSettled: 0.9))))
    }

    @Test func markerWaitsForTheTextToSettle() {
        #expect(AnswerTrigger.decide(live("Come gestite le disiscrizioni dalla neo",
                                          audioSilence: 1.2, textSettled: 0.1)) == .wait)
        // Seen live: «Quanto costa aggiungere una seconda» fired 0.5 s after
        // the last update, before «lingua» arrived.
        #expect(AnswerTrigger.decide(live("Quanto costa aggiungere una seconda",
                                          audioSilence: 1.4, textSettled: 0.6)) == .wait)
    }

    @Test func clientStillSpeakingWaitsEvenWithAQuestionMark() {
        #expect(AnswerTrigger.decide(live("Quanto costa una seconda lingua?",
                                          audioSilence: 0.1, textSettled: 2)) == .wait)
    }

    @Test func endpointIsWhenTheAudioWentQuiet() {
        #expect(AnswerTrigger.decide(live("Quando andate online col sito?", audioSilence: 0.8, textSettled: 0.2))
            == .fire(question: "Quando andate online col sito?", endpointAt: now - 0.8))
    }

    // Real client questions about ongoing work, 2026-11-16.
    @Test func possiamoIsARequest() {
        #expect(fires(AnswerTrigger.decide(input("Possiamo mettere la sola installazione anche per i quadrisplit", clientSilence: 1.2))))
    }

    @Test func markerWaitsUntilTheTextCaughtUpWithTheAudio() {
        // Audio quiet for 1.3 s, text unchanged for 0.9 s but last updated
        // before the audio stopped: the end of the question is still coming.
        let pending = "Come funziona l'IVA al dieci per cento nel carre"
        #expect(AnswerTrigger.decide(TriggerInput(
            pending: pending, now: now, lastClientActivity: now - 1.4, lastClientSpeech: now - 1.3,
            lastMeActivity: nil, answered: []
        )) == .wait)
        #expect(fires(AnswerTrigger.decide(TriggerInput(
            pending: pending + "llo", now: now, lastClientActivity: now - 0.9, lastClientSpeech: now - 1.8,
            lastMeActivity: nil, answered: []
        ))))
    }

    @Test func questionDropsALeadingFragment() {
        #expect(AnswerTrigger.questionText("llo? Avete già provato un ordine vero") == "Avete già provato un ordine vero")
        #expect(AnswerTrigger.questionText("Sì? Quando?") == "Sì? Quando?")
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
