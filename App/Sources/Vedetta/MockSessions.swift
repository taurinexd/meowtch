import Foundation
import VedettaKit

/// Fake sessions for the M1 skeleton — replaced by real hook events in M2.
/// The lineup exercises every visual state: question with blinking dot,
/// waiting with blinking bar + assistant reply, running with spinner and
/// tool line, plus two minimized sessions rendered as compact lines.
@MainActor
enum MockSessions {
    static func seed(into store: SessionStore) {
        let now = Date()
        store.upsert(AgentSession(
            id: "mock-vedetta",
            agent: .claude,
            title: "vedetta-notch-coding-agent",
            directory: "/Users/dev/Code/vedetta",
            gitBranch: "main",
            model: "claude-fable-5",
            currentTool: "Edit",
            currentToolDetail: "NotchView.swift",
            lastMessage: "last UI touches before moving on to M2: 1)…",
            state: .needsApproval,
            startedAt: now.addingTimeInterval(-3600),
            lastActivityAt: now.addingTimeInterval(-2),
            tasks: SessionTasks(items: [
                SessionTasks.Item(id: "1", subject: "Explore project context", status: "completed"),
                SessionTasks.Item(id: "2", subject: "Ask clarifying questions", status: "completed"),
                SessionTasks.Item(id: "3", subject: "M2.3 — HookConfigurator (TDD)", status: "in_progress"),
                SessionTasks.Item(id: "4", subject: "M2.1 — EventServer Unix socket", status: "pending"),
            ])
        ))
        store.upsert(AgentSession(
            id: "mock-starforge-checkout",
            agent: .claude,
            title: "checkout-redesign",
            directory: "/Users/dev/Code/starforge",
            gitBranch: "feat/checkout-redesign",
            model: "claude-fable-5",
            lastMessage: "go ahead with the three fixes from the review",
            lastAssistantMessage: "Checkout redesign: the three review fixes are merged and the production deploy is finishing. Next step: verify the analytics tag on staging.",
            state: .waitingForInput,
            startedAt: now.addingTimeInterval(-1800),
            lastActivityAt: now.addingTimeInterval(-60)
        ))
        store.upsert(AgentSession(
            id: "mock-starforge-crm",
            agent: .claude,
            title: "crm-upgrade",
            directory: "/Users/dev/Code/starforge",
            gitBranch: "feat/crm-upgrade",
            model: "claude-fable-5",
            currentTool: "Bash",
            currentToolDetail: "vendor/bin/phpstan analyse --memory-limit=1G",
            lastMessage: "go ahead with the CRM module upgrade",
            state: .running,
            startedAt: now.addingTimeInterval(-540),
            lastActivityAt: now.addingTimeInterval(-5)
        ))
        store.upsert(AgentSession(
            id: "mock-rosewood",
            agent: .claude,
            title: "gift-cards",
            directory: "/Users/dev/Code/rosewood-shop",
            state: .completed,
            startedAt: now.addingTimeInterval(-7200),
            lastActivityAt: now.addingTimeInterval(-3600),
            isMinimized: true
        ))
        store.upsert(AgentSession(
            id: "mock-atlas",
            agent: .claude,
            title: "banner-drop",
            directory: "/Users/dev/Code/design/atlas",
            state: .waitingForInput,
            startedAt: now.addingTimeInterval(-5400),
            lastActivityAt: now.addingTimeInterval(-2400),
            isMinimized: true
        ))
    }
}
