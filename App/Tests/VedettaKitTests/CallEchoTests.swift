import Foundation
import Testing
@testable import VedettaKit

struct CallEchoTests {
    private let t0 = Date(timeIntervalSince1970: 1_000_000)

    private func transcript(_ lines: [(CallSpeaker, String, TimeInterval)]) -> CallTranscript {
        var transcript = CallTranscript()
        for (speaker, text, offset) in lines {
            transcript.apply(.init(speaker: speaker, text: text, isFinal: true, at: t0.addingTimeInterval(offset)))
        }
        return transcript
    }

    @Test func micRepeatingTheClientIsEcho() {
        // Shape of the 2026-11-25 call on the MacBook speakers.
        let t = transcript([
            (.client, "Dato che siamo qui, stiamo cercando di vedere come far arrivare su Shopify un tag", 0),
            (.me, "Dato che siamo qui stiamo cercando di vedere come far arrivare su Shopify e un pag", 0.4),
        ])
        #expect(CallEcho.isEcho(t.lines[1], in: t))
        #expect(CallEcho.lastOwnSpeech(in: t) == nil)
    }

    @Test func matteoAnsweringIsNotEcho() {
        let t = transcript([
            (.client, "Quando pensate di finire il negozio?", 0),
            (.me, "Direi che per la fine del mese ci siamo con la parte catalogo", 3),
        ])
        #expect(!CallEcho.isEcho(t.lines[1], in: t))
        #expect(CallEcho.lastOwnSpeech(in: t) == t.lines[1].updatedAt)
    }

    @Test func distantClientLinesDoNotMakeEcho() {
        let t = transcript([
            (.client, "stiamo cercando di vedere come far arrivare il tag", 0),
            (.me, "stiamo cercando di vedere come far arrivare il tag", 60),
        ])
        #expect(!CallEcho.isEcho(t.lines[1], in: t))
    }

    @Test func echoNoLongerSuppressesTheQuestion() {
        let t = transcript([
            (.client, "Potete mandarci il preventivo per i flussi di recensione?", 0),
            (.me, "potete mandarci il preventivo per i flussi di recensione", 0.5),
        ])
        let now = t0.addingTimeInterval(2)
        let pending = t.lines[0].text
        let withEcho = AnswerTrigger.decide(TriggerInput(
            pending: pending, now: now, lastClientActivity: t0,
            lastMeActivity: t.lines[1].updatedAt, answered: []
        ))
        #expect(withEcho == .consume(reason: .meSpeaking))
        let filtered = AnswerTrigger.decide(TriggerInput(
            pending: pending, now: now, lastClientActivity: t0,
            lastMeActivity: CallEcho.lastOwnSpeech(in: t), answered: []
        ))
        #expect(filtered == .fire(question: pending, endpointAt: t0))
    }
}
