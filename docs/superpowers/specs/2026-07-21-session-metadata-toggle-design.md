# Session Metadata Toggle Design

## Goal

Make the optional metadata line beneath a full session card predictable across
Claude and Codex. It is globally disabled by default and, when enabled from the
future Settings window, displays the available values in this order:

`git branch · model · reasoning effort`

Permission mode is not part of this presentation.

## Scope and presentation

- One global persisted preference controls every Claude and Codex card.
- The default is `false`, including for users upgrading from the current build.
- Only full cards may render the line. Compact/minimized rows never render it.
- Missing values are omitted; placeholders are never rendered.
- If all three values are missing, the line is absent even while the preference
  is enabled.
- The existing monospaced secondary style and single-line truncation remain.

The current milestone does not build the Settings window. It establishes a
stable preference key and live observation boundary so the future Settings
control can bind to it without changing card code.

## Architecture

`AgentSession` owns source-neutral metadata fields: `gitBranch`, `model`, and a
new `reasoningEffort`. Its presentation projection returns only non-empty values
in the required order. `permissionMode` remains available for approval and
diagnostic logic but is excluded from the projection.

One preference definition owns the stable UserDefaults key
`showSessionMetadata`. `NotchView` observes it through SwiftUI and passes the
result down to every full `SessionRowView`; rows do not read UserDefaults
independently. This gives all cards one live value and avoids provider-specific
visibility decisions.

## Source ingestion

- Codex: parse the latest rollout `turn_context.payload.effort`, falling back to
  `turn_context.payload.collaboration_mode.settings.reasoning_effort` when
  necessary. Hooks may populate the same field if a future observed payload
  includes it, but no undocumented field is assumed.
- Claude: extract the latest non-empty top-level `effort` from transcript JSONL
  entries during the existing peek/full-scan enrichment paths.
- A missing or malformed effort value leaves `reasoningEffort` nil and never
  blocks other metadata.

## Data flow

1. Provider ingestion normalizes effort into `AgentSession.reasoningEffort`.
2. `AgentSession.presentationMetadata` returns branch/model/effort only.
3. `NotchView` observes the single global preference.
4. A full row renders the line only when the preference is enabled and the
   projection is non-empty.
5. Future Settings writes the same preference key; open cards update live.

## Verification

- Model tests assert the exact ordering, omission of missing values, and
  exclusion of permission mode.
- Codex rollout tests cover direct `effort` and nested reasoning-effort fallback.
- Claude transcript tests cover effort extraction and latest-value semantics.
- Presentation-policy tests assert default-off, global on/off behavior, full-row
  only visibility, and absence when every value is missing.
- Run `make test`, `make build`, and `make app`; then launch the rebuilt app once
  and verify the current cards no longer show the line with the default setting.

## Out of scope

- The Settings window and its broader information architecture.
- Placeholder metadata.
- Metadata on compact/minimized rows.
- Provider-specific toggles.
- Reusing permission mode as a substitute for reasoning effort.
