# Codex Terminal Parity and Claude Verification Design

## Goal

Complete Vedetta's Codex integration for sessions running in IDE terminals,
using the installed Vibe Island binary as the primary behavioural source of
truth. After Codex reaches parity, independently verify the existing Claude
integration against the same binary evidence and fix in-scope discrepancies.

This is a clean-room reimplementation. Vedetta reproduces externally observed
behaviour and deployed configuration shapes; it does not copy proprietary
source, branding, or assets.

## Evidence priority

Implementation decisions use this order:

1. The installed Vibe Island main binary, bundled helpers, embedded manifests,
   and black-box input/output captures.
2. Runtime logs and configuration written by those binaries.
3. Vedetta's binary audit and current source.
4. Codex or Claude documentation, used only to interpret or safely exercise an
   observed interface.

When lower-priority evidence conflicts with the installed Vibe Island build,
the Vibe Island behaviour wins. The audited baseline is Vibe Island 1.0.42,
build commit `49491ec0d07a`, with `vibe-island-hook 1.4.0`.

## Scope

### Included

- Codex CLI sessions launched in integrated IDE terminals, initially VS Code
  and compatible IDEs already supported by Vedetta's terminal identity layer.
- Live cards, accurate state, current tool, prompt and response text, title,
  model, permission mode, subagent detail, jump, approvals, usage, recovery,
  and configuration lifecycle.
- The six Codex hooks installed by Vibe Island, with the same timeouts.
- Hybrid hook and rollout ingestion with explicit ownership and deduplication.
- Incremental rollout and session-index monitoring.
- Persistent local Codex app-server access for usage, hook inspection, trust,
  and turn policy.
- Default and custom Codex config homes.
- Native-terminal approval fallback when Vedetta is absent or cannot safely
  answer.
- Built-in filtering of known Codex background workers.
- A post-Codex audit and correction pass for Claude terminal integration.

### Excluded

- Codex Desktop and Claude Desktop.
- Accessibility scanning for desktop approval dialogs.
- SSH and remote hosts.
- Cloud reset signals, licensing, analytics, or telemetry.
- Other coding agents.
- Modifying the user's Codex `notify` configuration.

## Observed Codex contract

Vibe Island installs exactly these global Codex hooks:

| Event | Timeout | Role |
|---|---:|---|
| `SessionStart` | 5 seconds | Thread identity and terminal binding |
| `UserPromptSubmit` | 5 seconds | Turn start and prompt |
| `PermissionRequest` | 7200 seconds | Blocking approval channel |
| `PostToolUse` | 5 seconds | Tool completion |
| `SubagentStop` | 5 seconds | Subagent completion and hierarchy |
| `Stop` | 5 seconds | Turn completion and final response |

The configuration envelope resembles Claude's hooks, but Codex payloads have
Codex-specific fields and semantics. Vibe Island's bridge namespaces the
session, retains the original thread and turn identifiers, normalizes shell
tools to `Bash`, attaches terminal and Git identity, and preserves tool input,
tool response, model, transcript path, and permission mode.

Vedetta does not need to reproduce this normalization inside the bridge. Its
bridge remains source-agnostic and transports the raw payload plus terminal
identity. A Codex-specific adapter in the app converts the raw event into the
same internal facts. This preserves the existing bridge boundary while
reproducing the observed behaviour.

If the app is unavailable during `PermissionRequest`, the bridge exits cleanly
without emitting allow or deny. Codex then retains its native terminal approval
path. Vedetta must never turn transport failure into authorization.

## Architecture

### 1. Hook configuration

`HookConfigurator` owns pure additive merge and removal operations. Codex uses
the exact six-event set above. `PermissionRequest` uses 7200 seconds; the other
events use 5 seconds. Existing user hook groups remain byte-semantically intact
apart from JSON reformatting required by the current writer.

`VedettaSetup` owns filesystem operations:

- discover the default `~/.codex` home and configured custom homes;
- create a timestamped backup before each change to an existing file;
- reject malformed configuration rather than replacing it with an empty map;
- atomically merge or remove only Vedetta handlers;
- self-heal a partial Vedetta installation without reinstalling after a
  deliberate removal;
- remove both Claude and Codex Vedetta entries during orphan cleanup;
- never edit `notify` or synthesize trusted hashes.

The Settings and onboarding surfaces report Claude and Codex independently. A
missing Codex installation must not make Claude setup fail, and vice versa.

### 2. Trust and feature state

`CodexAppServerClient` becomes a long-lived actor with request IDs, response
multiplexing, bounded startup, idle shutdown, and restart backoff. The same
connection serves usage and hook-management requests.

The app checks:

- whether Codex hooks are disabled by an explicit feature override;
- the result of `hooks/list` for every Vedetta handler;
- whether safe app-server authorization is available;
- whether manual `/hooks` confirmation is required.

Vedetta may clear an explicit `hooks = false` override only after a direct user
action in Settings. It authorizes hooks through Codex's own API when supported;
otherwise it presents precise `/hooks` instructions. It never fabricates
`hooks.state` entries.

### 3. Codex event adapter

`CodexEventAdapter` converts a raw hook envelope into typed facts:

- namespaced session ID plus original thread ID;
- turn ID and tool-use ID;
- event kind, model, permission mode, cwd, transcript path;
- tool name, input, output, prompt, and final assistant response;
- subagent parent, role, and nickname where present;
- terminal identity captured by `VedettaBridge`.

Namespacing prevents collisions with Claude IDs. The original Codex thread ID
remains available for session-index, rollout, app-server, and approval-policy
lookups.

### 4. Incremental rollout ingestion

`CodexRolloutTailer` maintains per-file byte offset and parse state. It reads
only appended complete JSONL records, preserves an incomplete final line for
the next read, detects truncation or replacement, and can rebuild state once
when recovery requires it.

The state machine tracks turns and tool calls by their IDs rather than global
booleans. It accepts `function_call` and `custom_tool_call`; custom tool input
may live in `payload.input` instead of `payload.arguments`. `exec`,
`exec_command`, `shell`, and `local_shell` normalize to `Bash`.

`CodexSessionIndexStore` tails `session_index.jsonl` and supplies the latest
informative thread title. Changes hydrate existing cards without restarting a
session.

### 5. Ingress coordination

`CodexIngressCoordinator` is the sole writer of Codex session state. It keeps a
revision per session and assigns field authority:

- Hooks own turn lifecycle, approval state, terminal identity, and explicit
  prompt/final-response fields.
- Rollout records own tool-start, detailed content, recovery, and completion
  evidence when an expected hook is missing.
- Session index owns informative thread titles.
- App-server owns usage, hook trust, and turn-policy snapshots.

On `Stop`, the coordinator marks the turn complete immediately and arms a short
rollout recovery window. Matching rollout completion enriches the card and is
deduplicated; a mismatched thread or turn is ignored. A late asynchronous read
cannot overwrite a newer hook revision. Sessions found before hooks are
installed remain fully recoverable from rollout data.

The existing periodic full refresh becomes a safety sweep, not the live data
path. FSEvents may coalesce paths, but each file is tailed once per batch and no
JSONL file is parsed twice for one change.

### 6. Approval handling

For terminal sessions, Vedetta supports:

- Follow focus: use the Notch when the user is away from the session terminal,
  otherwise leave the request in the terminal.
- Always in Notch.
- Always in Terminal.
- Native Codex approvals: observe session state but never intercept or notify
  for approvals.

Auto-reviewed requests remain silent. Approval policy, configured reviewer,
sandbox policy, turn ID, and tool-use ID form the request fingerprint so stale
or duplicate requests cannot resolve a newer approval.

When Vedetta owns a request, the socket remains open until allow, deny,
explicit handoff to terminal, connection loss, or the hook timeout. The app
returns the original Codex-compatible `hookSpecificOutput` decision shape. Any
ambiguous or failed state hands control back to Codex instead of authorizing.

### 7. Session presentation and filtering

Codex cards show the same terminal-centric information as Claude cards:

- informative title, repository and branch;
- user prompt and latest assistant response;
- current tool and target;
- model and permission mode;
- parent-aware subagent detail;
- jump only when a verified terminal identity exists.

Built-in admission rules suppress known background-only sessions: Guardian or
AutoReview, memory consolidation and writer sessions, Chronicle summaries,
Codex App suggested-prompt workers, Git-helper prompts, and Codex Companion
`task-worker` sessions launched by the Claude integration. Admission is checked
both when a rollout is first discovered and after title hydration: if a late
`session_index.jsonl` update reveals an internal worker, its provisional card
and terminal mapping are removed. Because desktop clients are out of scope,
desktop-only workers are filtered rather than presented or controlled.

`session_index.jsonl` is a live title source, not startup metadata. A later
`thread_name` for an existing thread replaces the first-prompt fallback as soon
as it is appended, without an app or session restart.

### 8. Usage

The persistent app-server client calls the observed account rate-limit method
and validates the response before replacing the last known good snapshot.
Rollout rate-limit events remain a fallback. Stale, incomplete, or non-account
snapshots cannot replace a valid account snapshot.

## Data flow

1. A Codex hook invokes `vedetta-bridge --source codex`.
2. The bridge captures terminal identity, wraps the untouched hook payload,
   writes one socket frame, and half-closes its write side.
3. `EventServer` dispatches the envelope to `CodexEventAdapter` and then
   `CodexIngressCoordinator`.
4. The coordinator correlates thread, turn, tool, rollout path, and terminal;
   it applies only fields for which that source is authoritative.
5. FSEvents later wakes the rollout and index tailers. Their revisions are
   accepted only if they still belong to the same session and turn.
6. Non-blocking hook events receive an immediate benign response. A Notch-owned
   permission keeps the connection open and returns the user's decision.

## Failure and recovery behaviour

- Missing app or socket: hook exits zero; native Codex behaviour continues.
- Malformed hook JSON: log metadata only, emit no authorization, and exit zero.
- Malformed user config: abort installation and preserve the file unchanged.
- App-server unavailable: keep the last known usage snapshot, report trust as
  unverified, and continue hook and rollout ingestion.
- Rollout partial line: retain it until the next append.
- Rollout truncation or replacement: reset that file's cursor and rebuild once.
- Hook/rollout identity mismatch: discard the rollout update.
- Duplicate or stale approval: never resolve another request.
- Missing `Stop`: rollout completion may close the turn after correlation.
- Missing rollout completion: `Stop` remains authoritative and the recovery
  window expires without changing the completed state.

## Privacy

All processing is local. Diagnostics may include event kind, anonymous counts,
durations, byte offsets, and whether identity fields were present. They must not
include rollout paths, prompts, assistant messages, tool arguments, tool
output, or file contents. No telemetry or network service is introduced.

## Testing strategy

Every behavioural change follows red-green-refactor.

Unit tests cover:

- exact six-hook merge, timeouts, idempotence, preservation, removal, malformed
  config rejection, and custom-home routing;
- raw Codex hook adaptation and namespacing;
- incremental append, partial line, truncation, custom-tool `input`, shell-name
  normalization, parallel call IDs, and live session-index rename updates;
- hook/rollout authority, revision ordering, identity mismatch, completion
  fallback, and duplicate suppression;
- approval fingerprints, routing modes, disconnect fallback, and exact output;
- app-server request multiplexing, restart, trust-state interpretation, and
  last-known-good usage behaviour;
- internal-worker admission rules, including provisional cards reclassified by
  a late `Codex Companion Task:` title.

Integration tests exercise bridge-to-socket framing and a fake local app-server
process. They do not alter real user configuration.

Manual acceptance uses temporary backup-verified configuration and requires a
real Codex session in an IDE terminal:

1. Start, prompt, tool activity, completion, and title all update correctly.
2. Jump selects the exact integrated terminal.
3. Allow and deny from the Notch affect the intended request.
4. Terminal/native routing leaves the request safely in Codex.
5. App restart and a pre-hook session recover without duplicate cards.
6. Renaming the Codex conversation updates the existing card without restart.
7. Claude-launched Codex Companion workers do not appear as user cards.
8. Existing foreign hooks and `notify` remain unchanged.
9. Removal restores a clean Vedetta-free configuration.

## Claude verification phase

After Codex acceptance passes, perform a fresh black-box comparison of Claude
terminal integration against Vibe Island 1.0.42. The review covers hook set and
timeouts, bridge normalization, lifecycle and completion arbitration, terminal
identity and jump, approvals and questions, subagents, titles, config lifecycle,
self-cleanup, failure fallback, filtering, usage, and diagnostic privacy.

Findings are added to `docs/vi-binary-audit.md` with their evidence level.
In-scope discrepancies are fixed with tests and committed separately from the
Codex implementation. Claude completion also requires a real IDE-terminal
session exercising card state, tool activity, jump, approval or question, and
turn completion.

## Delivery sequence

1. Preserve and correct the paused Codex hook-configuration patch.
2. Implement typed Codex hook adaptation and bridge safety.
3. Replace full rollout parsing with incremental tailing and session-index
   updates.
4. Add ingress authority, revisioning, and completion recovery.
5. Consolidate usage and trust onto a persistent app-server client.
6. Add approval routing, custom homes, worker filtering, and Settings status.
7. Run automated tests and real Codex terminal acceptance.
8. Update the binary audit with confirmed payloads and decisions.
9. Audit, correct, and manually verify Claude terminal integration.

Each sequence item lands as a focused local commit on `main`. Nothing is
pushed.
