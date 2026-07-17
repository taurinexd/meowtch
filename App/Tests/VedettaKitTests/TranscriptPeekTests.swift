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

    @Test func sessionNameComesFromNamingReminder() {
        let named = """
        {"type":"user","message":{"role":"user","content":[{"type":"text","text":"<system-reminder>\\nThe user named this session \\"early-access\\". This may indicate intent.</system-reminder>"}]}}
        """ + "\n" + fixture
        let peek = TranscriptPeek.parse(Data(named.utf8))
        #expect(peek.sessionName == "early-access")
        // il reminder non inquina il primo prompt vero
        #expect(peek.firstUserPrompt == "sistema il checkout del sito")
    }

    @Test func laterRenameWins() {
        let renamed = """
        {"type":"user","message":{"role":"user","content":[{"type":"text","text":"<system-reminder>\\nThe user named this session \\"vecchio\\".</system-reminder>"}]}}
        """ + "\n" + fixture + "\n" + """
        {"type":"user","message":{"role":"user","content":[{"type":"text","text":"<system-reminder>\\nThe user named this session \\"nuovo\\".</system-reminder>"}]}}
        """
        let peek = TranscriptPeek.parse(Data(renamed.utf8))
        #expect(peek.sessionName == "nuovo")
    }

    @Test func commandAndMetaEntriesAreNotPrompts() {
        let meta = """
        {"type":"user","message":{"role":"user","content":[{"type":"text","text":"<local-command-caveat>Caveat: roba generata</local-command-caveat>"}]}}
        {"type":"user","message":{"role":"user","content":[{"type":"text","text":"<command-name>/theme</command-name>"}]}}
        """ + "\n" + fixture
        let peek = TranscriptPeek.parse(Data(meta.utf8))
        #expect(peek.firstUserPrompt == "sistema il checkout del sito")
        #expect(peek.lastUserText == "sistema il checkout del sito")
    }

    @Test func aiTitleEntriesAreCaptured() {
        let withTitle = """
        {"type":"ai-title","aiTitle":"integrate-ultraplan-bundle-review","sessionId":"s1"}
        """ + "\n" + fixture
        let peek = TranscriptPeek.parse(Data(withTitle.utf8))
        #expect(peek.aiTitle == "integrate-ultraplan-bundle-review")
        // it does not pollute the first real prompt
        #expect(peek.firstUserPrompt == "sistema il checkout del sito")
    }

    @Test func agentNameCountsAsAiTitle() {
        let withAgent = """
        {"type":"agent-name","agentName":"kamal-crm-upgrade","sessionId":"s1"}
        """ + "\n" + fixture
        #expect(TranscriptPeek.parse(Data(withAgent.utf8)).aiTitle == "kamal-crm-upgrade")
    }

    @Test func emptyDataYieldsNothing() {
        let peek = TranscriptPeek.parse(Data())
        #expect(peek.firstUserPrompt == nil)
        #expect(peek.lastAssistantText == nil)
    }
}
