# Lifecycle Regression Repair Verification

Date: 2026-07-21

## Outcome

The lifecycle regression had two independent causes, both introduced while adding live Codex rollout ingestion:

1. `SessionBootstrap.refreshScannedSessions` allowed the transcript-mtime heuristic to overwrite live Claude hook state every 15 seconds. A recent transcript changed a completed green session back to blue until the 45-second activity window expired.
2. `CodexRolloutTailer` did not consume `turn_aborted` or `thread_rolled_back`. An aborted turn therefore remained in `activeTurnIDs`, so a later completed turn could not return the session to waiting/green.

The adjacent scan found a third lifecycle leak: a completed turn could leave an unmatched `openTools` entry visible in the next turn. Turn completion, abort and rollback now clear stale tools when no active turn remains.

## Implemented boundaries

- Live Claude lifecycle is hook-owned. Transcript polling skips state and message mutation for those sessions, while its separate recap/reasoning-effort enrichment remains enabled.
- Adopted Claude sessions without hooks retain the transcript fallback.
- Codex retains rollout ingestion beside hooks, with coordinator revision checks as its convergence boundary.
- `task_complete`, `turn_aborted` and `thread_rolled_back` all close or invalidate in-flight Codex state.

## Regression tests

The changes were developed red/green:

- `SessionRefreshPolicyTests` first failed to compile before the policy existed, then proved all three routes: live Claude off, adopted Claude on, Codex on.
- `abortedTurnCannotKeepSessionRunning` and `threadRollbackClearsAllInflightState` first reproduced the leaked running state.
- `completedTurnClearsUnmatchedOpenTools` first reproduced the stale tool leak after correcting the JSONL fixture escaping.

Final suite: **111 tests in 18 suites, 0 failures**.

## Real-data scan

Current Codex rollout files contained these `event_msg.payload.type` values:

- `token_count`: 706
- `agent_message`: 160
- `patch_apply_end`: 118
- `user_message`: 42
- `thread_settings_applied`: 38
- `task_started`: 36
- `task_complete`: 33
- `web_search_end`: 6
- `context_compacted`: 6
- `turn_aborted`: 1
- `thread_rolled_back`: 1

The observed failing rollout contained `task_started` for turn `019f84c1…`, followed by `turn_aborted`, `thread_rolled_back`, then a new `task_started`/`task_complete`. That exact event shape is covered by the rollout tailer tests. `context_compacted` is intentionally not terminal and does not close a turn.

All writers and transitions touching `AgentSession.state`, `lastActivityAt`, `liveEventIds`, coordinator upserts, bootstrap refresh and full-scan enrichment were inspected. No additional lifecycle-authority violation was found. The metadata-toggle work is presentation-only and does not write lifecycle state.

## Package and live verification

Executed from the repository root:

```text
make test
make build
make app
codesign --verify --deep --strict --verbose=2 dist/Vedetta.app
```

Results:

- Debug build completed.
- Production app bundle completed.
- Helper and app signatures validated; the app satisfies its designated requirement.
- The packaged app was restarted once and is running from `dist/Vedetta.app`.

The socket-level lifecycle check reused an existing Claude session, so it created no test card:

1. Send `SessionStart` through the real Unix socket.
2. Wait 17 seconds, longer than one periodic refresh interval: state remained `running`.
3. Send `Stop` through the same socket.
4. Wait another 17 seconds: state remained `waitingForInput`, with `currentTool` cleared.

This directly exercises the production `EventServer` → dispatcher → reducer → periodic bootstrap path that previously changed the color after expanding the notch.

## Commits

- `ec54a88 fix: preserve live Claude lifecycle authority`
- `d8ec3d6 fix: close aborted Codex rollout turns`
- `6649075 fix: clear Codex tools at turn boundaries`

No push was performed.
