import Foundation
import VedettaKit

/// Fake sessions for the M1 skeleton — replaced by real hook events in M2.
@MainActor
enum MockSessions {
    static let tasks: [String: MockTaskList] = [
        "mock-vedetta": MockTaskList(
            done: 7,
            inProgress: "M1: skeleton app menu bar + pannello notch con dati finti",
            completedVisible: [
                "Esplorare contesto progetto (repo GitHub + sito vibeisland.app)",
                "Fare domande di chiarimento per ridimensionare lo scope",
            ]
        ),
    ]

    static func seed(into store: SessionStore) {
        let now = Date()
        store.upsert(AgentSession(
            id: "mock-uptonica",
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
            id: "mock-vedetta",
            agent: .claude,
            title: "vedetta-notch-coding-agent",
            directory: "/Users/matteomorena/Code/vedetta",
            gitBranch: "main",
            model: "claude-fable-5",
            currentTool: "Edit",
            currentToolDetail: "NotchView.swift",
            lastMessage: "ci sono anche i settings dell'app, che non so s…",
            state: .needsApproval,
            startedAt: now.addingTimeInterval(-3600),
            lastActivityAt: now.addingTimeInterval(-2)
        ))
        store.upsert(AgentSession(
            id: "mock-lestelle",
            agent: .codex,
            title: "sync-product-feed",
            directory: "/Users/matteomorena/Code/le-stelle-wp",
            gitBranch: "main",
            model: "gpt-5.5",
            lastMessage: "allinea il feed prodotti con Mexal",
            state: .completed,
            startedAt: now.addingTimeInterval(-7200),
            lastActivityAt: now.addingTimeInterval(-1800)
        ))
    }
}
