import Testing
@testable import VedettaKit

struct ChipVisibilityTests {
    private let vscode = TerminalInfo(termProgram: "vscode")
    private let iterm = TerminalInfo(termProgram: "iTerm.app")

    @Test func singleAgentAndOnlyVSCodeHidesBoth() {
        let v = ChipVisibility(sessions: [(.claude, vscode), (.claude, vscode), (.claude, nil)])
        #expect(v.showAgent == false)
        #expect(v.showHost == false)
    }

    @Test func secondAgentBringsAgentChipsBack() {
        let v = ChipVisibility(sessions: [(.claude, vscode), (.codex, vscode)])
        #expect(v.showAgent == true)
        #expect(v.showHost == false)
    }

    @Test func anotherKnownTerminalBringsHostChipsBack() {
        let v = ChipVisibility(sessions: [(.claude, vscode), (.claude, iterm)])
        #expect(v.showAgent == false)
        #expect(v.showHost == true)
    }

    @Test func terminalWithoutHostAppDoesNotCount() {
        let v = ChipVisibility(sessions: [(.claude, vscode), (.claude, TerminalInfo(tty: "/dev/ttys004"))])
        #expect(v.showHost == false)
    }

    @Test func vscodeByBundleIdentifierCounts() {
        #expect(TerminalInfo(bundleIdentifier: "com.microsoft.VSCode").isVSCode)
        #expect(!TerminalInfo(termProgram: "Apple_Terminal").isVSCode)
    }
}
