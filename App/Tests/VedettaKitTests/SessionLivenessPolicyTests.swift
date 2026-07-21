import Foundation
import Testing
@testable import VedettaKit

struct SessionLivenessPolicyTests {
    private func session(
        lastActivityAt: Date = Date(timeIntervalSince1970: 1_000)
    ) -> AgentSession {
        AgentSession(
            id: "s",
            agent: .claude,
            title: "t",
            directory: "/repo",
            state: .waitingForInput,
            startedAt: Date(timeIntervalSince1970: 0),
            lastActivityAt: lastActivityAt
        )
    }

    @Test func keepsSessionsWithoutTerminalEvidence() {
        #expect(!SessionLivenessPolicy.shouldRemove(
            session: session(),
            terminal: nil,
            isPidAttachedToTTY: { _, _ in false },
            isProcessAlive: { _ in false }
        ))
        // A tty with no usable ancestry (only the dead bridge) is not
        // positive evidence either.
        #expect(!SessionLivenessPolicy.shouldRemove(
            session: session(),
            terminal: TerminalInfo(tty: "/dev/ttys004", pidChain: [111]),
            isPidAttachedToTTY: { _, _ in false },
            isProcessAlive: { _ in false }
        ))
    }

    @Test func keepsHookSessionWhileAnAncestorHoldsTheTTY() {
        let terminal = TerminalInfo(tty: "/dev/ttys004", pidChain: [111, 222, 333])
        #expect(!SessionLivenessPolicy.shouldRemove(
            session: session(),
            terminal: terminal,
            isPidAttachedToTTY: { pid, tty in pid == 333 && tty == "/dev/ttys004" },
            isProcessAlive: { _ in true }
        ))
    }

    @Test func removesHookSessionWhenNoAncestorHoldsTheTTY() {
        // Killed terminal tab: shell and agent are gone; the bridge pid
        // (chain head) never counts.
        let terminal = TerminalInfo(tty: "/dev/ttys004", pidChain: [111, 222, 333])
        #expect(SessionLivenessPolicy.shouldRemove(
            session: session(),
            terminal: terminal,
            isPidAttachedToTTY: { pid, _ in pid == 111 },
            isProcessAlive: { _ in true }
        ))
    }

    @Test func fallbackWriterDeathNeedsTheQuietGrace() {
        let terminal = TerminalInfo(pid: 500, pidChain: [500, 600])
        let now = Date(timeIntervalSince1970: 1_030)
        // Writer died 30s after the last activity: still inside the grace,
        // a resumed thread may rebind a new writer.
        #expect(!SessionLivenessPolicy.shouldRemove(
            session: session(),
            terminal: terminal,
            isPidAttachedToTTY: { _, _ in false },
            isProcessAlive: { _ in false },
            now: now
        ))
        let later = Date(timeIntervalSince1970: 1_000 + SessionLivenessPolicy.fallbackGrace + 1)
        #expect(SessionLivenessPolicy.shouldRemove(
            session: session(),
            terminal: terminal,
            isPidAttachedToTTY: { _, _ in false },
            isProcessAlive: { _ in false },
            now: later
        ))
        // A live writer always keeps the card.
        #expect(!SessionLivenessPolicy.shouldRemove(
            session: session(),
            terminal: terminal,
            isPidAttachedToTTY: { _, _ in false },
            isProcessAlive: { _ in true },
            now: later
        ))
    }
}
