import Foundation
import Testing
@testable import VedettaKit

struct CallTranscriptTests {
    private let t0 = Date(timeIntervalSinceReferenceDate: 1_000_000)

    private func update(_ speaker: CallSpeaker, _ text: String, final: Bool, at offset: TimeInterval) -> CallTranscript.Update {
        CallTranscript.Update(speaker: speaker, text: text, isFinal: final, at: t0 + offset)
    }

    @Test func volatileUpdatesReplaceTheOpenLine() {
        var t = CallTranscript()
        t.apply(update(.client, "Ma il carrello", final: false, at: 0))
        t.apply(update(.client, "Ma il carrello misto", final: false, at: 1))
        #expect(t.lines.count == 1)
        #expect(t.lines[0].text == "Ma il carrello misto")
        #expect(t.lines[0].isFinal == false)
        #expect(t.liveLine?.text == "Ma il carrello misto")
    }

    @Test func finalClosesTheLineAndNextUpdateOpensANewOne() {
        var t = CallTranscript()
        t.apply(update(.client, "Funziona già", final: false, at: 0))
        t.apply(update(.client, "Funziona già?", final: true, at: 1))
        t.apply(update(.client, "e poi", final: false, at: 2))
        #expect(t.lines.count == 2)
        #expect(t.lines[0].text == "Funziona già?")
        #expect(t.lines[0].isFinal)
        #expect(t.lines[1].text == "e poi")
        #expect(t.lines[1].isFinal == false)
        #expect(t.lines[0].startedAt == t0)
        #expect(t.lines[0].updatedAt == t0 + 1)
    }

    @Test func channelsKeepSeparateOpenLines() {
        var t = CallTranscript()
        t.apply(update(.client, "Allora", final: false, at: 0))
        t.apply(update(.me, "Sì", final: false, at: 1))
        t.apply(update(.client, "Allora, quando?", final: true, at: 2))
        #expect(t.lines.count == 2)
        #expect(t.lines.first { $0.speaker == .client }?.isFinal == true)
        #expect(t.lines.first { $0.speaker == .me }?.isFinal == false)
        #expect(t.liveLine?.speaker == .me)
    }

    @Test func blankUpdatesAreIgnored() {
        var t = CallTranscript()
        t.apply(update(.client, "   ", final: false, at: 0))
        t.apply(update(.me, "\n", final: true, at: 1))
        #expect(t.lines.isEmpty)
        #expect(t.liveLine == nil)
    }

    @Test func recentReturnsTheLastLinesInOrder() {
        var t = CallTranscript()
        for i in 0..<5 {
            t.apply(update(.client, "riga \(i)", final: true, at: TimeInterval(i)))
        }
        #expect(t.recent(3).map(\.text) == ["riga 2", "riga 3", "riga 4"])
        #expect(t.recent(10).count == 5)
    }
}
