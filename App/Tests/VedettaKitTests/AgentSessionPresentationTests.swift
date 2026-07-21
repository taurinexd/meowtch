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
            reasoningEffort: "high",
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
            "main", "gpt-5.6", "high",
        ])
    }

    @Test func metadataOmitsMissingValuesAndPermissionMode() {
        let session = AgentSession(
            id: "claude-session",
            agent: .claude,
            title: "Work",
            directory: "/Code/vedetta",
            model: "claude-fable-5",
            permissionMode: "bypassPermissions",
            state: .waitingForInput,
            startedAt: .distantPast,
            lastActivityAt: .distantPast
        )

        #expect(session.presentationMetadata == ["claude-fable-5"])
    }

    @Test func oneGlobalPolicyShowsMetadataOnlyOnEnabledFullRows() {
        let metadata = ["main", "gpt-5.6", "medium"]
        #expect(!SessionMetadataPresentation.shouldShow(
            enabled: false, isCompact: false, metadata: metadata
        ))
        #expect(SessionMetadataPresentation.shouldShow(
            enabled: true, isCompact: false, metadata: metadata
        ))
        #expect(!SessionMetadataPresentation.shouldShow(
            enabled: true, isCompact: true, metadata: metadata
        ))
        #expect(!SessionMetadataPresentation.shouldShow(
            enabled: true, isCompact: false, metadata: []
        ))
        #expect(SessionMetadataPresentation.defaultsKey == "showSessionMetadata")
    }

    @Test func jumpRequiresCapturedHostAndProcessOrWindowIdentity() {
        #expect(!TerminalInfo().isJumpable)
        #expect(!TerminalInfo(bundleIdentifier: "com.microsoft.VSCode").isJumpable)
        #expect(TerminalInfo(
            bundleIdentifier: "com.microsoft.VSCode",
            pidChain: [42, 7]
        ).isJumpable)
        #expect(TerminalInfo(
            termProgram: "vscode",
            pidChain: [42, 7]
        ).isJumpable)
        #expect(TerminalInfo(
            bundleIdentifier: "com.apple.Terminal",
            windowId: 99
        ).isJumpable)
    }
}
