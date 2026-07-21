# Lifecycle Regression Repair Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Restore immediate, stable lifecycle colors for live Claude and Codex terminal sessions and audit recent state-ingestion changes for adjacent regressions.

**Architecture:** Keep hook-owned Claude lifecycle isolated from the 15-second transcript heuristic while preserving live recap/effort enrichment. Extend the Codex rollout state machine so every observed terminal event (`task_complete`, `turn_aborted`, `thread_rolled_back`) closes stale active turns. Express the Claude routing decision as a pure VedettaKit policy so it has a permanent regression test.

**Tech Stack:** Swift 6, Swift Testing, JSONL rollout fixtures, SwiftUI app runtime.

## Global Constraints

- Vibe Island terminal behavior remains the primary source of truth.
- Hooks own live lifecycle; transcript polling must never overwrite live Claude state.
- Codex rollout remains active beside hooks and must converge after abort/rollback.
- Use `make test`, never plain `swift test`.
- Work on local `main`, commit locally, never push.
- Do not restart Vedetta until the final packaged build is ready.

---

### Task 1: Protect live Claude lifecycle from transcript polling

**Files:**
- Create: `App/Sources/VedettaKit/SessionRefreshPolicy.swift`
- Modify: `App/Sources/Vedetta/SessionBootstrap.swift`
- Create: `App/Tests/VedettaKitTests/SessionRefreshPolicyTests.swift`

**Interfaces:**
- Produces: `SessionRefreshPolicy.shouldApplyStateHeuristic(agent:hasLiveHook:) -> Bool`.

- [x] Add a failing test proving the heuristic is disabled for live Claude, enabled for adopted Claude, and enabled for Codex regardless of hook presence.
- [x] Run `make test`; expect compile failure because `SessionRefreshPolicy` does not exist.
- [x] Implement the pure policy and use it to skip the state-mutating first pass for live Claude sessions. Keep the existing second pass for recap/effort only.
- [x] Run `make test`; require green.

### Task 2: Close aborted and rolled-back Codex turns

**Files:**
- Modify: `App/Sources/VedettaKit/CodexRolloutTailer.swift`
- Modify: `App/Tests/VedettaKitTests/CodexRolloutTailerTests.swift`

**Interfaces:**
- Consumes: rollout `event_msg.payload.type`.
- Produces: an empty `activeTurnIDs` set after `turn_aborted` or `thread_rolled_back`.

- [x] Add failing JSONL tests reproducing the observed aborted-turn leak and rollback cleanup.
- [x] Run `make test`; expect the snapshots to remain incorrectly `.running`.
- [x] Remove the matching turn on `turn_aborted`; clear active turns and open tools on `thread_rolled_back` because the rollback invalidates in-flight state.
- [x] Run `make test`; require green.

### Task 3: Adjacent regression scan and final verification

**Files:**
- Create: `docs/verification/2026-07-21-lifecycle-regression-repair.md`
- Modify: this plan to mark completed steps.

**Interfaces:**
- Verifies every writer of `AgentSession.state` and every observed Codex terminal event type.

- [x] Compare all `session.state` writers against their authority boundary and enumerate real rollout event kinds from current JSONL files.
- [x] Inspect the diff from the pre-Codex-parity baseline through `HEAD` for state, active-turn, polling and metadata changes.
- [x] Run `make test && make build && make app`, then `codesign --verify --deep --strict dist/Vedetta.app`.
- [x] Restart Vedetta once; verify Claude Start/Stop remains stable beyond one refresh interval and replay the real aborted/completed Codex sequence in the rollout state machine.
- [x] Record exact evidence, run `git diff --check`, confirm a clean worktree, and commit.
