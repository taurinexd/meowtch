# Codex Jump Parity Correction — Verification

Date: 2026-07-21

## Root cause

Hook-driven Codex sessions carried the same terminal identity as Claude. A Codex CLI session already open when hooks were installed was adopted only from its rollout, so it had no `TerminalInfo`. The UI deliberately ignores taps without a verified jump target; the full Codex card therefore looked interactive but did nothing.

VI covers this case by retaining the rollout writer PID. Static binary evidence includes `codexWriterPid`, `codexRolloutPath`, `CodexWriterInfo`, `WriterLookupOutcome`, `/usr/sbin/lsof`, `-F`, and the common `JumpInput` fields `pid`, `tty`, `bundleId`, `ideWindowId`, `codexThreadId`.

## Implementation

- Parse one field-oriented lsof snapshot into rollout-path→writer-PID mappings.
- Walk the writer ancestry and require a supported IDE host (`com.microsoft.VSCode`).
- Bind that fallback to rollout-only sessions without replacing a later hook identity.
- Parse rollout `originator`, `source` and `thread_source`.
- Reject Codex Desktop and Claude companion rollouts before they can create a transient card.

## Automated evidence

The change was developed red/green. Coverage includes:

- lsof record parsing;
- writer ancestry→VS Code terminal identity;
- rejection when no supported IDE ancestor exists;
- fallback attachment and hook precedence;
- origin parsing;
- early exclusion of Codex Desktop and internal Claude companion sessions.

Final suite: **118 tests in 19 suites, 0 failures**.

## Live evidence

- Real rollout owner: PID `15557` has the current `019f83c2…jsonl` open for writing.
- Recovered chain: `15557 → 15549 → 10814 → 8026 → 8004`.
- Host resolved to `com.microsoft.VSCode`; the terminal binding was persisted for `codex-019f83c2-d6ad-73f0-9a6b-d28883274fee`.
- The production VS Code focus URI returned `owns=true` for `/Users/matteomorena/Code/vedetta`, proving the extension selected the correct workspace/terminal route.
- Socket dump contains the current `codex-vedetta` session and no `Codex Companion Task:`/known companion thread.
- Debug build, production bundle and strict deep code-sign verification passed.
- Packaged Vedetta was restarted from `dist/Vedetta.app`.

Commit: `d6c5261 fix: restore Codex terminal jump parity`. No push was performed.
