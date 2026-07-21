# Session Metadata Toggle Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Hide session metadata by default and provide one future-Settings-ready global preference that shows available branch, model, and genuine reasoning effort on full Claude and Codex cards.

**Architecture:** Normalize provider effort into `AgentSession.reasoningEffort`, keep display ordering in the model, and centralize visibility in a pure policy plus one SwiftUI `@AppStorage` value at `NotchView`. Provider parsers remain responsible only for extraction; rows receive one global Boolean and never read preferences independently.

**Tech Stack:** Swift 6, SwiftUI, Foundation/UserDefaults, Swift Testing, JSONL fixtures.

## Global Constraints

- The preference key is `showSessionMetadata` and defaults to `false`.
- Only full cards may show metadata; compact/minimized rows never do.
- Display order is branch, model, reasoning effort; permission mode is excluded.
- Missing values are omitted and no placeholders are rendered.
- Do not build the Settings window or add a temporary menu control.
- Use `make test`, never plain `swift test` on this machine.
- Work on local `main`, commit incrementally, and never push.

---

### Task 1: Define provider-neutral metadata and visibility policy

**Files:**
- Modify: `App/Sources/VedettaKit/AgentSession.swift`
- Modify: `App/Tests/VedettaKitTests/AgentSessionPresentationTests.swift`

**Interfaces:**
- Produces: `AgentSession.reasoningEffort: String?`
- Produces: `SessionMetadataPresentation.defaultsKey: String`
- Produces: `SessionMetadataPresentation.shouldShow(enabled:isCompact:metadata:) -> Bool`

- [x] Add failing tests asserting `presentationMetadata == ["main", "gpt-5.6", "high"]`, permission mode exclusion, missing-value omission, and visibility only for enabled full rows with non-empty metadata.
- [x] Run `make test`; expect failures because `reasoningEffort` and `SessionMetadataPresentation` do not exist and the projection still includes permission mode.
- [x] Add `reasoningEffort` to `AgentSession` and change the projection:

```swift
public var presentationMetadata: [String] {
    [gitBranch, model, reasoningEffort].compactMap { value in
        value?.isEmpty == false ? value : nil
    }
}

public enum SessionMetadataPresentation {
    public static let defaultsKey = "showSessionMetadata"
    public static func shouldShow(enabled: Bool, isCompact: Bool, metadata: [String]) -> Bool {
        enabled && !isCompact && !metadata.isEmpty
    }
}
```

- [x] Run `make test`; expect all tests to pass.
- [x] Commit with `feat: define global session metadata policy`.

### Task 2: Extract genuine effort from Claude and Codex

**Files:**
- Modify: `App/Sources/VedettaKit/TranscriptPeek.swift`
- Modify: `App/Sources/VedettaKit/CodexRolloutTailer.swift`
- Modify: `App/Tests/VedettaKitTests/TranscriptPeekTests.swift`
- Modify: `App/Tests/VedettaKitTests/CodexRolloutTailerTests.swift`

**Interfaces:**
- Produces: `TranscriptPeek.reasoningEffort: String?`
- Produces: `CodexRolloutSnapshot.reasoningEffort: String?`

- [x] Add a Claude fixture with successive top-level `effort` values and assert the latest non-empty value wins.
- [x] Add Codex `turn_context` fixtures asserting direct `payload.effort` wins and nested `collaboration_mode.settings.reasoning_effort` is the fallback.
- [x] Run `make test`; expect failures because neither parser exposes effort.
- [x] In `TranscriptPeek.parse`, capture non-empty top-level `effort` before message parsing; merge tail over head in `read`.
- [x] In `CodexRolloutTailer.consume`, handle `type == "turn_context"` before requiring `payload.type`:

```swift
let nested = ((payload["collaboration_mode"] as? [String: Any])?["settings"] as? [String: Any])?["reasoning_effort"] as? String
snapshot.reasoningEffort = Self.nonEmpty(payload["effort"] as? String) ?? Self.nonEmpty(nested)
```

- [x] Run `make test`; expect all tests to pass.
- [x] Commit with `feat: extract reasoning effort from agent records`.

### Task 3: Propagate effort and bind one global UI preference

**Files:**
- Modify: `App/Sources/VedettaKit/CodexIngressCoordinator.swift`
- Modify: `App/Sources/VedettaKit/SessionEventReducer.swift`
- Modify: `App/Sources/Vedetta/SessionBootstrap.swift`
- Modify: `App/Sources/Vedetta/UI/NotchView.swift`
- Modify: `App/Sources/Vedetta/UI/SessionRowView.swift`
- Modify: relevant tests in `App/Tests/VedettaKitTests/`

**Interfaces:**
- Consumes: provider parser `reasoningEffort` fields from Task 2.
- Consumes: `SessionMetadataPresentation` from Task 1.
- Produces: `SessionRowView.showSessionMetadata: Bool`.

- [x] Add failing coordinator/reducer tests proving parsed effort reaches the session and a newer parsed value replaces an older one.
- [x] Run `make test`; expect failures because ingestion does not assign `reasoningEffort`.
- [x] Assign Codex rollout effort in `CodexIngressCoordinator.apply(rollout:)`; assign Claude peek effort in bootstrap adoption/refresh and reducer enrichment/reply refresh.
- [x] Add one root observation in `NotchView`:

```swift
@AppStorage(SessionMetadataPresentation.defaultsKey)
private var showSessionMetadata = false
```

- [x] Pass `showSessionMetadata` to every full `SessionRowView` call and `false` to compact rows. Add `var showSessionMetadata = false` on the row and gate the line through `SessionMetadataPresentation.shouldShow`.
- [x] Run `make test`; expect all tests to pass.
- [x] Commit with `feat: gate session metadata behind global preference`.

### Task 4: Regression, package, and live default-off verification

**Files:**
- Modify: `docs/verification/2026-07-21-session-metadata-toggle.md`

**Interfaces:**
- Verifies the stable UserDefaults key without exposing a temporary control.

- [x] Run `make test && make build && make app`; require exit 0 and record the test count.
- [x] Read `defaults read app.vedetta.macos showSessionMetadata`; absence is valid and means false. If an inherited development value exists, back up the domain before clearing only this key for the default-off test.
- [x] Restart Vedetta once with the packaged app and inspect the live panel/socket: full cards show no metadata line by default and compact rows remain unchanged.
- [x] Temporarily set `showSessionMetadata=true`, verify full cards use branch/model/effort with missing values omitted and compact rows remain unchanged, then restore the prior preference value.
- [x] Run `git diff --check`, inspect `git status --short`, and write the exact evidence in the verification document.
- [x] Commit with `docs: verify global session metadata toggle`.
