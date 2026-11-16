import Foundation
import Testing
@testable import VedettaKit

struct CallTurnsTests {
    private let t0 = Date(timeIntervalSinceReferenceDate: 1_000_000)

    private func update(_ speaker: CallSpeaker, _ text: String, final: Bool, at offset: TimeInterval) -> CallTranscript.Update {
        CallTranscript.Update(speaker: speaker, text: text, isFinal: final, at: t0 + offset)
    }

    @Test func pendingIsClientTextAfterTheMark() {
        var t = CallTranscript()
        t.apply(update(.client, "Buongiorno a tutti", final: true, at: 0))
        var turns = CallTurns()
        turns.consumeAll(in: t)
        t.apply(update(.client, "Il carrello funziona già?", final: false, at: 2))
        #expect(turns.pending(in: t) == "Il carrello funziona già?")
    }

    @Test func consumeAllCutsTheOpenLineByCharacters() {
        var t = CallTranscript()
        t.apply(update(.client, "Quando consegnate?", final: false, at: 0))
        var turns = CallTurns()
        turns.consumeAll(in: t)
        t.apply(update(.client, "Quando consegnate? E quanto costa?", final: false, at: 3))
        #expect(turns.pending(in: t) == "E quanto costa?")
    }

    @Test func pendingJoinsSeveralClientLines() {
        var t = CallTranscript()
        t.apply(update(.client, "Allora,", final: true, at: 0))
        t.apply(update(.client, "quando consegnate?", final: false, at: 1))
        #expect(CallTurns().pending(in: t) == "Allora, quando consegnate?")
    }

    @Test func myLinesNeverCountAsPending() {
        var t = CallTranscript()
        t.apply(update(.me, "Allora vi spiego", final: false, at: 0))
        #expect(CallTurns().pending(in: t) == "")
    }

    @Test func lastClientTextJoinsTheLastClientLines() {
        var t = CallTranscript()
        t.apply(update(.client, "Uno.", final: true, at: 0))
        t.apply(update(.me, "Sì.", final: true, at: 1))
        t.apply(update(.client, "Due.", final: true, at: 2))
        t.apply(update(.client, "Tre?", final: false, at: 3))
        #expect(CallTurns().lastClientText(in: t, lines: 2) == "Due. Tre?")
    }
}
