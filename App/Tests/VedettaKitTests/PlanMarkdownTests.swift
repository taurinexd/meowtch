import Testing
@testable import VedettaKit

struct PlanMarkdownTests {
    @Test func headingsLoseTheirHashes() {
        let blocks = PlanMarkdown.blocks(from: "# Piano\n## Step\n### Dettaglio")
        #expect(blocks == [
            .heading(level: 1, text: "Piano"),
            .heading(level: 2, text: "Step"),
            .heading(level: 3, text: "Dettaglio"),
        ])
    }

    @Test func softWrappedLinesBecomeOneParagraph() {
        let blocks = PlanMarkdown.blocks(from: "Prima riga\nsua continuazione\n\nAltro capoverso")
        #expect(blocks == [
            .paragraph("Prima riga sua continuazione"),
            .paragraph("Altro capoverso"),
        ])
    }

    @Test func bulletsKeepTheirNestingAndDropTheMarker() {
        let blocks = PlanMarkdown.blocks(from: "- primo\n* secondo\n  - annidato")
        #expect(blocks == [
            .bullet(depth: 0, text: "primo"),
            .bullet(depth: 0, text: "secondo"),
            .bullet(depth: 1, text: "annidato"),
        ])
    }

    /// The numbers are the content here — an ordered plan renumbered by the
    /// renderer would misdescribe the plan.
    @Test func orderedItemsKeepTheirOwnNumbers() {
        let blocks = PlanMarkdown.blocks(from: "1. uno\n2. due\n10) dieci")
        #expect(blocks == [
            .ordered(depth: 0, marker: "1.", text: "uno"),
            .ordered(depth: 0, marker: "2.", text: "due"),
            .ordered(depth: 0, marker: "10.", text: "dieci"),
        ])
    }

    @Test func quotesLoseTheirAngleBracket() {
        let blocks = PlanMarkdown.blocks(from: "> una nota\n> che continua\n\ndopo")
        #expect(blocks == [.quote("una nota che continua"), .paragraph("dopo")])
    }

    /// Inside a fence nothing is markdown: hashes and dashes are code.
    @Test func fencedCodeIsPreservedVerbatim() {
        let blocks = PlanMarkdown.blocks(from: "```swift\n# non è un titolo\n- non è un elenco\n```")
        #expect(blocks == [.code("# non è un titolo\n- non è un elenco")])
    }

    @Test func unterminatedFenceStillYieldsItsCode() {
        #expect(PlanMarkdown.blocks(from: "```\nlet x = 1") == [.code("let x = 1")])
    }

    @Test func rulesBecomeDividers() {
        #expect(PlanMarkdown.blocks(from: "a\n\n---\n\nb") == [
            .paragraph("a"), .divider, .paragraph("b"),
        ])
    }

    /// Inline syntax is left in place: the view parses it so bold and code
    /// spans still render inside a heading or a list item.
    @Test func inlineSyntaxSurvivesUntouched() {
        #expect(PlanMarkdown.blocks(from: "- Variante: **A** con `preview`") == [
            .bullet(depth: 0, text: "Variante: **A** con `preview`"),
        ])
    }

    @Test func emptyInputYieldsNothing() {
        #expect(PlanMarkdown.blocks(from: "   \n\n  ").isEmpty)
    }

    /// The plan from the notch screenshot, end to end.
    @Test func aRealPlanParsesIntoItsBlocks() {
        let plan = """
        # Piano di prova — sessione di test di plan mode

        > Sessione di test del flusso plan mode + AskUserQuestion.

        Scelte registrate dal test delle opzioni:
        - Variante selezionata: **Variante A** (single-select con preview)

        ## Step

        1. Confermare che la domanda single-select con preview è stata resa.
        2. Chiudere la sessione con ExitPlanMode.
        """
        #expect(PlanMarkdown.blocks(from: plan) == [
            .heading(level: 1, text: "Piano di prova — sessione di test di plan mode"),
            .quote("Sessione di test del flusso plan mode + AskUserQuestion."),
            .paragraph("Scelte registrate dal test delle opzioni:"),
            .bullet(depth: 0, text: "Variante selezionata: **Variante A** (single-select con preview)"),
            .heading(level: 2, text: "Step"),
            .ordered(depth: 0, marker: "1.", text: "Confermare che la domanda single-select con preview è stata resa."),
            .ordered(depth: 0, marker: "2.", text: "Chiudere la sessione con ExitPlanMode."),
        ])
    }
}
