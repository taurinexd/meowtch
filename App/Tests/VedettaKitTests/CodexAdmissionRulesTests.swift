import Testing
@testable import VedettaKit

struct CodexAdmissionRulesTests {
    @Test func suppressesObservedBackgroundWorkers() {
        let titles = [
            "Codex Companion Task: Implement hook integration",
            "Guardian: review changes",
            "AutoReview worker",
            "Memory writer",
            "Memory consolidation",
            "Chronicle summary",
            "Codex App suggested prompts",
            "Git helper",
        ]
        for title in titles {
            #expect(!CodexAdmissionRules.shouldAdmit(title: title), "worker visibile: \(title)")
        }
        #expect(!CodexAdmissionRules.shouldAdmit(
            title: "ordinary title",
            metadata: ["worker_kind": "task-worker"]
        ))
    }

    @Test func admitsNormalTerminalThreads() {
        #expect(CodexAdmissionRules.shouldAdmit(title: "Implement Codex support"))
        #expect(CodexAdmissionRules.shouldAdmit(title: "Fix git helper documentation"))
        #expect(CodexAdmissionRules.shouldAdmit(title: nil))
    }

    @Test func rolloutOriginExcludesDesktopAndInternalCompanionsBeforeTitleArrives() {
        #expect(!CodexAdmissionRules.shouldAdmit(
            title: nil,
            metadata: ["originator": "Codex Desktop", "source": "vscode"]
        ))
        #expect(!CodexAdmissionRules.shouldAdmit(
            title: nil,
            metadata: ["originator": "Claude Code", "source": "vscode"]
        ))
        #expect(CodexAdmissionRules.shouldAdmit(
            title: nil,
            metadata: [
                "originator": "codex-tui",
                "source": "cli",
                "thread_source": "user",
            ]
        ))
        #expect(CodexAdmissionRules.shouldAdmit(
            title: nil,
            metadata: [
                "originator": "codex_exec",
                "source": "exec",
                "thread_source": "user",
            ]
        ))
    }
}
