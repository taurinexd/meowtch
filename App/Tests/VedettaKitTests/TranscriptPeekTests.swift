import Testing
import Foundation
@testable import VedettaKit

struct TranscriptPeekTests {

    private let fixture = """
    {"type":"user","message":{"role":"user","content":[{"type":"text","text":"sistema il checkout del sito"}]},"sessionId":"s1"}
    {"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"Guardo il modulo checkout."}]}}
    {"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","name":"Bash","input":{"command":"ls"}}]}}
    {"type":"user","message":{"role":"user","content":[{"type":"tool_result","content":"file.txt"}]}}
    {"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"Fatto: il checkout ora valida il CAP."}]}}
    """

    @Test func extractsFirstUserPrompt() {
        let peek = TranscriptPeek.parse(Data(fixture.utf8))
        #expect(peek.firstUserPrompt == "sistema il checkout del sito")
    }

    @Test func extractsLastAssistantText() {
        let peek = TranscriptPeek.parse(Data(fixture.utf8))
        #expect(peek.lastAssistantText == "Fatto: il checkout ora valida il CAP.")
    }

    @Test func extractsLastUserText() {
        let peek = TranscriptPeek.parse(Data(fixture.utf8))
        // il tool_result non è un messaggio "vero" dell'utente
        #expect(peek.lastUserText == "sistema il checkout del sito")
    }

    @Test func toleratesMalformedLines() {
        let dirty = "non-json garbage\n" + fixture + "\n{broken"
        let peek = TranscriptPeek.parse(Data(dirty.utf8))
        #expect(peek.lastAssistantText == "Fatto: il checkout ora valida il CAP.")
    }

    @Test func sidechainEntriesAreIgnored() {
        let withSidechain = fixture + "\n" + """
        {"type":"assistant","isSidechain":true,"message":{"role":"assistant","content":[{"type":"text","text":"Fatto. Task creata col tuo PAT."}]}}
        """
        let peek = TranscriptPeek.parse(Data(withSidechain.utf8))
        #expect(peek.lastAssistantText == "Fatto: il checkout ora valida il CAP.")
    }

    @Test func emptyDataYieldsNothing() {
        let peek = TranscriptPeek.parse(Data())
        #expect(peek.firstUserPrompt == nil)
        #expect(peek.lastAssistantText == nil)
    }
}
