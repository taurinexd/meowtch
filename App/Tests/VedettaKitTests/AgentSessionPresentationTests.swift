import Testing
@testable import VedettaKit

struct AgentSessionPresentationTests {
    @Test func exposesCodexTerminalMetadataWithoutLosingConversationTitle() {
        let session = AgentSession(
            id: "codex-thread",
            agent: .codex,
            title: "Live renamed title",
            directory: "/Code/vedetta",
            gitBranch: "main",
            model: "gpt-5.6",
            permissionMode: "on-request",
            parentSessionID: "codex-parent",
            subagentRole: "reviewer",
            subagentNickname: "lint",
            state: .running,
            startedAt: .distantPast,
            lastActivityAt: .distantPast
        )

        #expect(session.title == "Live renamed title")
        #expect(session.presentationMetadata == [
            "main", "gpt-5.6", "on-request", "reviewer: lint",
        ])
    }

    @Test func jumpRequiresCapturedHostAndProcessOrWindowIdentity() {
        #expect(!TerminalInfo().isJumpable)
        #expect(!TerminalInfo(bundleIdentifier: "com.microsoft.VSCode").isJumpable)
        #expect(TerminalInfo(
            bundleIdentifier: "com.microsoft.VSCode",
            pidChain: [42, 7]
        ).isJumpable)
        #expect(TerminalInfo(
            bundleIdentifier: "com.apple.Terminal",
            windowId: 99
        ).isJumpable)
    }
}
