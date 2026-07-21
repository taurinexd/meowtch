# Codex Terminal Parity Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Do not delegate without Matteo's explicit authorization.

**Goal:** Reproduce the observed Vibe Island 1.0.42 behaviour for Codex CLI sessions in IDE terminals, then verify and correct Claude terminal support against the same binary evidence.

**Architecture:** Keep the bridge source-agnostic and introduce typed Codex facts plus one ingress coordinator as the sole Codex state writer. Hooks, rollout JSONL, the session index, and the persistent app-server remain concurrent sources with explicit field authority, identity correlation, and revision-based stale-write rejection.

**Tech Stack:** Swift 6, Swift Package Manager, AppKit/SwiftUI, Foundation actors and process I/O, FSEvents, XCTest, Unix domain sockets, JSONL.

## Global constraints

- Treat the audited Vibe Island binary and its installed runtime/configuration as the highest-priority source of truth.
- Support Codex CLI and Claude Code in IDE terminals only; desktop clients are out of scope.
- Never modify Codex `notify`, fabricate trust hashes, or authorize on ambiguous/failure paths.
- Back up every existing config file before mutation, use atomic replacement, and preserve unrelated user entries.
- Keep Claude and Codex installation/status failures independent.
- Work directly on local `main`, commit each completed task, and never push.
- Preserve the inherited uncommitted patch until its useful pieces have either passed the tests below or been replaced.
- For every production change: add the named test first, run `make test` and observe the expected failure, implement the minimum correction, then rerun `make test`. Do not invoke plain `swift test` on this macOS 26 Command Line Tools setup because the Makefile supplies the required `Testing.framework` paths.
- Do not claim completion without an actual Codex terminal session and an actual Claude terminal session exercising the verified paths.

## Task 1: Lock the exact VI hook contract

**Files:**

- Modify: `App/Sources/VedettaKit/HookConfigurator.swift`
- Modify: `App/Tests/VedettaKitTests/HookConfiguratorTests.swift`

- [ ] Replace inherited expectations with tests asserting the exact Codex set: `SessionStart`, `UserPromptSubmit`, `PermissionRequest`, `PostToolUse`, `SubagentStop`, `Stop`.
- [ ] Assert Codex timeout `7200` only for `PermissionRequest`, `5` for every other event, and matcher `""` only for `PostToolUse`.
- [ ] Assert Claude retains its existing source-specific timeout and matcher contract.
- [ ] Assert additive merge preserves unrelated groups and removal deletes only Vedetta handlers.
- [ ] Assert a second merge is idempotent and does not duplicate handlers.
- [ ] Run `make test`; confirm the inherited ten-event/86400 implementation fails in `HookConfiguratorTests`.
- [ ] Introduce source-specific hook descriptors rather than one shared timeout table.
- [ ] Rerun focused tests and `make test`.
- [ ] Commit: `fix: match VI Codex hook manifest exactly`.

## Task 2: Make hook-file mutation recoverable and independent

**Files:**

- Add: `App/Sources/VedettaKit/HookConfigFileStore.swift`
- Add: `App/Tests/VedettaKitTests/HookConfigFileStoreTests.swift`
- Modify: `App/Sources/Vedetta/VedettaSetup.swift`
- Modify: `App/Sources/Vedetta/OnboardingController.swift`
- Modify: `App/Sources/Vedetta/StatusItemController.swift`

- [ ] Test writing a missing file, merging a valid file, rejecting malformed JSON unchanged, timestamping a backup before mutation, and atomically replacing the destination.
- [ ] Test per-agent results so a Codex failure cannot mark Claude failed and vice versa.
- [ ] Test deliberate removal disables automatic healing until the user explicitly reinstalls.
- [ ] Run `make test`; confirm the new `HookConfigFileStoreTests` fail before implementation.
- [ ] Move pure filesystem planning/validation into `HookConfigFileStore`; keep AppKit presentation in `VedettaSetup`.
- [ ] Install/heal/remove both sources independently and preserve every unrelated key, including `notify`.
- [ ] Render independent Claude and Codex status/action rows in onboarding and the status menu.
- [ ] Rerun focused tests and `make test`.
- [ ] Commit: `feat: manage Claude and Codex hooks independently`.

## Task 3: Decode Codex hooks into typed facts

**Files:**

- Add: `App/Sources/VedettaKit/CodexHookEvent.swift`
- Add: `App/Tests/VedettaKitTests/CodexHookEventTests.swift`
- Modify: `App/Sources/VedettaKit/AgentSession.swift`
- Modify: `App/Sources/Vedetta/EventDispatcher.swift`

- [ ] Add fixtures for all six observed events, including original `session_id`, `turn_id`, tool-use ID, model, permission mode, cwd, transcript path, prompt, final response, tool input/output, subagent metadata, and captured terminal identity.
- [ ] Test namespacing to `codex-<thread-id>` while retaining the unmodified thread ID for correlation.
- [ ] Test `exec`, `exec_command`, `shell`, and `local_shell` normalize to `Bash`.
- [ ] Test missing or malformed fields produce a non-authorizing parse failure with metadata-safe diagnostics.
- [ ] Test the raw bridge response for `Stop` remains `{"continue":true}` and `PermissionRequest` transport failure emits no decision.
- [ ] Run `make test`; confirm the new `CodexHookEventTests` fail before implementation.
- [ ] Implement `CodexHookEvent` and `CodexFact` as `Sendable` value types and add only the identity fields required by presentation/correlation to `AgentSession`.
- [ ] Route Codex envelopes through the adapter; leave Claude on `SessionEventReducer`.
- [ ] Remove payload-body diagnostic logging; retain event kind, source, IDs, and parse result only.
- [ ] Rerun focused tests and `make test`.
- [ ] Commit: `feat: adapt Codex hook payloads to typed facts`.

## Task 4: Tail rollout JSONL incrementally and by identity

**Files:**

- Replace: `App/Sources/VedettaKit/CodexScan.swift`
- Add: `App/Sources/VedettaKit/CodexRolloutTailer.swift`
- Replace: `App/Tests/VedettaKitTests/CodexScanTests.swift`
- Add: `App/Tests/VedettaKitTests/CodexRolloutTailerTests.swift`

- [ ] Test cursor advancement reads appended bytes once, buffers an incomplete final line, and resets safely after truncation/replacement.
- [ ] Test `function_call` and `custom_tool_call`, including `payload.input` as well as `payload.arguments`.
- [ ] Test parallel call IDs independently; completing one call must not close another.
- [ ] Test shell-name normalization and extraction of prompt, assistant content, completion, rate-limit fallback, thread ID, turn ID, and rollout path.
- [ ] Delete the inherited `shouldApplyRollout` test and replace it with a test proving rollout enrichment remains active after live hooks appear.
- [ ] Run both focused suites and confirm failures for double full-file parsing, `payload.input`, parallel calls, and fallback-only gating.
- [ ] Implement a per-file cursor, partial-line buffer, file identity, and ID-keyed turn/tool state.
- [ ] Preserve a one-time rebuild path for startup/recovery; make normal FSEvent handling append-only.
- [ ] Rerun focused tests and `make test`.
- [ ] Commit: `feat: ingest Codex rollouts incrementally`.

## Task 5: Hydrate live titles and suppress internal workers

**Files:**

- Add: `App/Sources/VedettaKit/CodexSessionIndexStore.swift`
- Add: `App/Sources/VedettaKit/CodexAdmissionRules.swift`
- Add: `App/Tests/VedettaKitTests/CodexSessionIndexStoreTests.swift`
- Add: `App/Tests/VedettaKitTests/CodexAdmissionRulesTests.swift`
- Modify: `App/Sources/VedettaKit/SessionStore.swift`

- [ ] Test append-only parsing of `session_index.jsonl`, latest-title-wins semantics, partial lines, truncation, and duplicate entries.
- [ ] Test that a renamed current thread replaces its first-prompt fallback without restart.
- [ ] Test suppression of the observed background categories, including titles beginning `Codex Companion Task:` and `task-worker` metadata.
- [ ] Test late reclassification removes both the provisional session and its terminal mapping.
- [ ] Run focused suites; confirm current startup-only title adoption and terminal leakage fail.
- [ ] Implement the index store and pure admission rules.
- [ ] Make `SessionStore.remove(id:)` remove associated terminal state atomically.
- [ ] Rerun focused tests and `make test`.
- [ ] Commit: `fix: refresh Codex titles and filter internal workers`.

## Task 6: Establish one hybrid Codex ingress authority

**Files:**

- Add: `App/Sources/VedettaKit/CodexIngressCoordinator.swift`
- Add: `App/Tests/VedettaKitTests/CodexIngressCoordinatorTests.swift`
- Modify: `App/Sources/VedettaKit/SessionStore.swift`

- [ ] Encode field authority tests: hooks own lifecycle/approval/terminal/prompt/final response; rollout owns tool-start/detail/recovery; index owns informative title; app-server owns usage/trust/policy snapshots.
- [ ] Test a stale rollout revision cannot overwrite a newer hook transition.
- [ ] Test matching `Stop` plus rollout completion deduplicates, missing `Stop` can recover from rollout, and missing rollout leaves `Stop` authoritative.
- [ ] Test thread/turn mismatch is rejected, parallel tools remain independent, and a title update cannot resurrect a suppressed worker.
- [ ] Test provisional rollout-only sessions converge when hooks later arrive.
- [ ] Run the focused suite and confirm the coordinator is absent.
- [ ] Implement a per-session revision ledger and completion-recovery window in an actor/main-actor-safe coordinator.
- [ ] Make the coordinator the only Codex writer to `SessionStore`.
- [ ] Rerun focused tests and `make test`.
- [ ] Commit: `feat: coordinate hybrid Codex ingress`.

## Task 7: Wire live rollout and index monitoring once

**Files:**

- Modify: `App/Sources/Vedetta/CodexWatcher.swift`
- Modify: `App/Sources/Vedetta/SessionBootstrap.swift`
- Modify: `App/Sources/Vedetta/AppDelegate.swift`
- Modify: `App/Sources/Vedetta/EventDispatcher.swift`
- Add: `App/Tests/VedettaKitTests/CodexIngressWiringTests.swift`

- [ ] Add a testable batch-routing layer proving coalesced FSEvents tail each changed file at most once and route rollout/index facts to the coordinator.
- [ ] Test startup performs one recovery scan and later changes are incremental.
- [ ] Test a hook received during an asynchronous rollout read wins by revision.
- [ ] Run the focused suite; confirm the current duplicate full-file read and startup-only index path fail.
- [ ] Watch both rollout roots and every configured `session_index.jsonl`; coalesce canonical paths per callback.
- [ ] Replace direct Codex store mutation in bootstrap/dispatcher with coordinator calls.
- [ ] Keep the 15-second full refresh only as a safety sweep.
- [ ] Rerun focused tests and `make test`.
- [ ] Commit: `refactor: wire Codex sources through one coordinator`.

## Task 8: Replace the one-shot app-server probe

**Files:**

- Add: `App/Sources/VedettaKit/CodexAppServerProtocol.swift`
- Add: `App/Tests/VedettaKitTests/CodexAppServerProtocolTests.swift`
- Add: `App/Sources/Vedetta/CodexAppServerClient.swift`
- Delete: `App/Sources/Vedetta/CodexUsageProbe.swift`
- Modify: `App/Sources/Vedetta/AppDelegate.swift`
- Modify: `App/Sources/Vedetta/UsageModel.swift`

- [ ] Test JSON-RPC request IDs, out-of-order response multiplexing, notifications, malformed frames, last-known-good rate-limit validation, bounded startup, idle shutdown, and exponential restart backoff using a fake transport.
- [ ] Test `hooks/list`, authorization capability/state, explicit hooks-disabled state, account rate limits, and turn policy parsing from captured/observed shapes.
- [ ] Run focused tests; confirm persistent/multiplexed APIs are absent.
- [ ] Implement a long-lived actor-backed process with one reader loop and pending-continuation table.
- [ ] Serve usage and hook/trust/policy reads from the same connection; retain rollout limits only as fallback.
- [ ] Never synthesize trust state; expose `verified`, `manualConfirmationRequired`, `disabled`, and `unavailable` explicitly.
- [ ] Rerun focused tests and `make test`.
- [ ] Commit: `feat: keep a persistent Codex app-server client`.

## Task 9: Match VI approval routing and safe fallback

**Files:**

- Add: `App/Sources/VedettaKit/CodexApprovalPolicy.swift`
- Add: `App/Tests/VedettaKitTests/CodexApprovalPolicyTests.swift`
- Modify: `App/Sources/Vedetta/ApprovalCenter.swift`
- Modify: `App/Sources/Vedetta/EventDispatcher.swift`
- Modify: `App/Sources/Vedetta/StatusItemController.swift`

- [ ] Test four modes: Follow focus, Always Notch, Always Terminal, Native Codex.
- [ ] Test auto-reviewed requests stay silent and native/terminal routing emits no hook decision.
- [ ] Test the fingerprint includes thread, turn, tool-use ID, permission policy, configured reviewer, and sandbox policy; stale/duplicate decisions cannot resolve a newer request.
- [ ] Test socket loss, app absence, timeout, malformed request, and ambiguity all hand control back to native Codex without allow/deny.
- [ ] Test a Notch-owned request returns the original Codex-compatible `hookSpecificOutput.decision` shape.
- [ ] Run focused tests and confirm the current shared Claude approval path fails Codex-specific cases.
- [ ] Implement pure routing/fingerprinting and persist the selected mode.
- [ ] Add status-menu controls and route blocking Codex sockets through `ApprovalCenter` only when Vedetta owns the request.
- [ ] Rerun focused tests and `make test`.
- [ ] Commit: `feat: match VI Codex approval routing`.

## Task 10: Support custom Codex config homes and trust UX

**Files:**

- Add: `App/Sources/VedettaKit/CodexHome.swift`
- Add: `App/Tests/VedettaKitTests/CodexHomeTests.swift`
- Modify: `App/Sources/Vedetta/VedettaSetup.swift`
- Modify: `App/Sources/Vedetta/StatusItemController.swift`
- Modify: `App/Sources/Vedetta/OnboardingController.swift`

- [ ] Test default-home discovery, canonical deduplication, custom home persistence, nonexistent paths, and independent per-home hook state.
- [ ] Test explicit `hooks = false` is reported but never silently changed.
- [ ] Test the user-initiated enable action uses Codex authorization when available and otherwise renders exact manual `/hooks` guidance.
- [ ] Run focused tests; confirm custom homes and trust states are absent.
- [ ] Implement a small home registry and an `NSOpenPanel` action for adding a Codex config directory.
- [ ] Install/watch/query each home independently and present its verified/manual/disabled/unavailable state.
- [ ] Preserve `notify` and never write hashes or undocumented trust state.
- [ ] Rerun focused tests and `make test`.
- [ ] Commit: `feat: support custom Codex homes and hook trust`.

## Task 11: Complete presentation parity

**Files:**

- Modify: `App/Sources/Vedetta/UI/NotchView.swift`
- Modify: `App/Sources/Vedetta/UI/SessionRowView.swift`
- Modify: `App/Sources/Vedetta/JumpService.swift`
- Modify: `App/Sources/Vedetta/StatusItemController.swift`
- Add/Modify tests under: `App/Tests/VedettaKitTests/`

- [ ] Add model tests proving Codex cards expose informative title, repository/branch, prompt, assistant response, current tool/target, model, permission mode, and parent-aware subagent detail.
- [ ] Test Jump is offered only with verified terminal identity.
- [ ] Test a removed/suppressed session cannot retain a blue/in-progress indicator.
- [ ] Run the focused tests and confirm missing fields fail.
- [ ] Bind the typed session fields to the existing compact/expanded UI without introducing desktop-only controls.
- [ ] Preserve Claude presentation and accessibility behaviour.
- [ ] Run `make test`, `make build`, and `make app`.
- [ ] Commit: `feat: finish Codex terminal card parity`.

## Task 12: Verify Codex end to end against VI

**Files:**

- Modify: `docs/vi-binary-audit.md`
- Add: `docs/verification/2026-07-21-codex-terminal-parity.md`

- [ ] Run `make test`, `make build`, and `make app`; record exit status and relevant counts.
- [ ] Back up the user's current Claude/Codex hook files, install the built app's handlers through its UI, and compare the resulting six-event Codex manifest to the captured VI baseline.
- [ ] Launch a fresh Codex CLI session in an IDE terminal and exercise prompt, shell tool, non-shell tool, approval, subagent completion, `Stop`, and Jump.
- [ ] Rename the active Codex conversation; use the socket dump to prove the live card title changes without app/session restart.
- [ ] Launch or detect a Codex Companion `task-worker`; prove no card or terminal mapping remains, including late index classification.
- [ ] Temporarily make Vedetta unavailable during a safe approval fixture and prove native Codex retains control with no synthetic allow/deny.
- [ ] Compare event/state/title/terminal/approval/usage evidence to the VI audit matrix and document every match or intentional scoped exclusion.
- [ ] Restore user configuration if the verification changed anything not intended to remain installed.
- [ ] Commit: `docs: verify Codex terminal parity against VI`.

## Task 13: Audit and correct Claude terminal integration

**Files:**

- Modify: `docs/vi-binary-audit.md`
- Modify: `App/Sources/VedettaKit/HookConfigurator.swift`
- Modify: `App/Sources/VedettaKit/SessionEventReducer.swift`
- Modify: `App/Sources/Vedetta/EventDispatcher.swift`
- Modify: `App/Sources/Vedetta/VedettaSetup.swift`
- Modify: relevant tests under `App/Tests/VedettaKitTests/`

- [ ] Re-run strings/symbol/config/log black-box inspection for VI's Claude hook manifest, bridge normalization, lifecycle mapping, approval response, worker filtering, terminal identity, configuration removal/healing, and failure fallback.
- [ ] Build a finding matrix with columns: observed VI behaviour, Vedetta behaviour, evidence, severity, required change.
- [ ] For each mismatch, add a focused regression test before modifying production code; run it and record the expected RED result.
- [ ] Correct only evidence-backed terminal-session discrepancies; do not add Claude Desktop behaviour.
- [ ] Verify existing Codex suites remain green after every shared-code change.
- [ ] Exercise a real Claude Code IDE-terminal session across prompt, tool, approval, subagent, stop, title, Jump, and app-unavailable fallback.
- [ ] Run `make test`, `make build`, and `make app`.
- [ ] Commit code: `fix: align Claude terminal integration with VI`.
- [ ] Commit evidence: `docs: complete VI Claude integration audit`.

## Task 14: Final regression and handoff

**Files:**

- Modify: `AGENTS.md` only if a stable operational rule discovered during verification belongs in the contract
- Modify: `docs/vi-binary-audit.md`
- Modify: `docs/verification/2026-07-21-codex-terminal-parity.md`

- [ ] Run `git diff --check` and inspect `git status --short` so no inherited or accidental edits are unaccounted for.
- [ ] Run the complete test/build/package sequence from a clean invocation: `make test && make build && make app`.
- [ ] Re-run the live socket dump while one Codex and one Claude terminal session are active; verify no duplicate/ghost sessions, current titles, terminal bindings, and stable completed states.
- [ ] Compare installed hook configs to the exact expected handlers while confirming unrelated entries and Codex `notify` remain unchanged.
- [ ] Confirm each config mutation created a restorable timestamped backup and document its path.
- [ ] Review the final diff and commit history against every acceptance criterion in the approved design.
- [ ] Commit: `chore: finalize terminal integration verification`.

## Acceptance checklist

- [ ] Codex installs exactly the six VI hooks with exact matchers/timeouts.
- [ ] Hooks and rollout remain complementary live sources with one coordinating writer.
- [ ] Rollout/index reads are incremental, identity-safe, and partial-line safe.
- [ ] Active conversation renames update cards live.
- [ ] Internal Codex workers never persist as visible or terminal-bound cards.
- [ ] Approval failures always fall back to native Codex and never authorize.
- [ ] Usage/trust/policy share one persistent app-server client.
- [ ] Default/custom homes are handled without touching `notify` or fabricating trust.
- [ ] Claude and Codex install/status paths are independent.
- [ ] Claude terminal behaviour is re-audited and corrected against VI after Codex.
- [ ] Unit, integration, package, Codex live, and Claude live verification evidence is recorded.
