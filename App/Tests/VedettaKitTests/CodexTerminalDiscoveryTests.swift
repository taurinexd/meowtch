import Testing
@testable import VedettaKit

struct CodexTerminalDiscoveryTests {
    @Test func writerLookupRepeatsOnlyAfterTheCachedProcessExits() {
        #expect(CodexTerminalFallback.shouldRefreshWriter(
            cachedOwnerPID: nil,
            isProcessAlive: { _ in false }
        ))
        #expect(!CodexTerminalFallback.shouldRefreshWriter(
            cachedOwnerPID: 15557,
            isProcessAlive: { $0 == 15557 }
        ))
        #expect(CodexTerminalFallback.shouldRefreshWriter(
            cachedOwnerPID: 15557,
            isProcessAlive: { _ in false }
        ))
    }

    @Test func openRolloutParserAssociatesFilesWithOwningCodexProcess() {
        let output = """
        p11251
        fcwd
        n/
        p15557
        fcwd
        n/Users/matteomorena/Code/vedetta
        f46
        n/Users/matteomorena/.codex/sessions/2026/07/21/rollout-live.jsonl
        f47
        n/Users/matteomorena/.codex/history.jsonl
        """

        #expect(CodexOpenRolloutFiles.parse(lsofOutput: output) == [
            "/Users/matteomorena/.codex/sessions/2026/07/21/rollout-live.jsonl": 15557,
        ])
    }

    @Test func fallbackUsesRolloutOwnerAncestryToRecoverVSCodeTerminal() {
        let parents: [Int32: Int32] = [15557: 15549, 15549: 10814, 10814: 8026, 8026: 8004]
        let bundles: [Int32: String] = [8026: "com.microsoft.VSCode.helper", 8004: "com.microsoft.VSCode"]

        let terminal = CodexTerminalFallback.resolve(
            ownerPID: 15557,
            parentOf: { parents[$0] },
            bundleIdentifierOf: { bundles[$0] }
        )

        #expect(terminal?.pid == 15557)
        #expect(terminal?.pidChain == [15557, 15549, 10814, 8026, 8004])
        #expect(terminal?.bundleIdentifier == "com.microsoft.VSCode")
        #expect(terminal?.termProgram == "vscode")
        #expect(terminal?.isJumpable == true)
    }

    @Test func fallbackRejectsAProcessWithNoSupportedIDEAncestor() {
        let terminal = CodexTerminalFallback.resolve(
            ownerPID: 42,
            parentOf: { $0 == 42 ? 1 : nil },
            bundleIdentifierOf: { _ in nil }
        )

        #expect(terminal == nil)
    }
}
