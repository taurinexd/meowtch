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
            directory: "/Users/matteomorena/Code/vedetta",
            gitBranch: "main",
            model: "claude-fable-5",
            currentTool: "Edit",
            currentToolDetail: "NotchView.swift",
            lastMessage: "ultime finezze UI prima di procedere con M2: 1)…",
            state: .needsApproval,
            startedAt: now.addingTimeInterval(-3600),
            lastActivityAt: now.addingTimeInterval(-2),
            tasks: SessionTasks(items: [
                SessionTasks.Item(id: "1", subject: "Esplorare contesto progetto", status: "completed"),
                SessionTasks.Item(id: "2", subject: "Fare domande di chiarimento", status: "completed"),
                SessionTasks.Item(id: "3", subject: "M2.3 — HookConfigurator (TDD)", status: "in_progress"),
                SessionTasks.Item(id: "4", subject: "M2.1 — EventServer socket Unix", status: "pending"),
            ])
        ))
        store.upsert(AgentSession(
            id: "mock-uptonica-integration",
            agent: .claude,
            title: "integration-tiktok-criteo",
            directory: "/Users/matteomorena/Code/uptonica",
            gitBranch: "feat/integration-tiktok-criteo",
            model: "claude-fable-5",
            lastMessage: "procedi coi tre fix segnalati da Kamal",
            lastAssistantMessage: "Integrazione TikTok/Criteo su Uptonica: i tre fix dei problemi segnalati da Kamal sono mergiati e il deploy in prod sta finendo. Prossimo passo: verifico la chip GTM su Clima.",
            state: .waitingForInput,
            startedAt: now.addingTimeInterval(-1800),
            lastActivityAt: now.addingTimeInterval(-60)
        ))
        store.upsert(AgentSession(
            id: "mock-uptonica-kamal",
            agent: .claude,
            title: "kamal-crm-upgrade",
            directory: "/Users/matteomorena/Code/uptonica",
            gitBranch: "feat/kamal-crm-upgrade",
            model: "claude-fable-5",
            currentTool: "Bash",
            currentToolDetail: "vendor/bin/phpstan analyse --memory-limit=1G",
            lastMessage: "procedi con l'upgrade del modulo CRM",
            state: .running,
            startedAt: now.addingTimeInterval(-540),
            lastActivityAt: now.addingTimeInterval(-5)
        ))
        store.upsert(AgentSession(
            id: "mock-lestelle",
            agent: .claude,
            title: "bomboniera",
            directory: "/Users/matteomorena/Code/le-stelle-wp",
            state: .completed,
            startedAt: now.addingTimeInterval(-7200),
            lastActivityAt: now.addingTimeInterval(-3600),
            isMinimized: true
        ))
        store.upsert(AgentSession(
            id: "mock-5om",
            agent: .claude,
            title: "banner-drop",
            directory: "/Users/matteomorena/Code/design/5om",
            state: .waitingForInput,
            startedAt: now.addingTimeInterval(-5400),
            lastActivityAt: now.addingTimeInterval(-2400),
            isMinimized: true
        ))
    }
}
