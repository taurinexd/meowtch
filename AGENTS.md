# AGENTS.md — Meowtch (codename: Vedetta)

Meowtch is an open-source macOS menu-bar app (LSUIElement, SwiftUI + AppKit) that
turns the MacBook notch into a control surface for AI coding agents — **Claude Code
and Codex**: live session cards, in-notch approvals and questions, jump-to-terminal,
usage strip. It is a clean-room reimplementation of the commercial **Vibe Island**
(black-box analysis of its deployed config/behaviour only; own name, branding, assets).

**Two names, one project.** *Meowtch* is what the user sees: display name,
`Meowtch.app`, DMG volume, release assets, README, Settings/onboarding copy.
*Vedetta* is the codename and stays everywhere internal — Swift targets, the
`app.vedetta.macos` bundle id, the executable, `~/.vedetta`, `vedetta-bridge`,
the signing identities. Never "fix" an internal Vedetta reference into Meowtch:
the bundle id and paths carry the user's TCC grants and installed hooks.

## Read first (canonical docs)
- **`docs/vi-binary-audit.md`** — the living knowledge base: Vibe Island cross-check,
  real payloads, decisions, gaps, and the session progress log. **Read before working.**
- `docs/superpowers/specs/` — the design spec and milestones (M1–M8).
- This file — the stable operating contract (keep it short; put discoveries in the audit).

## Rules
- **Don't assume Codex has no hooks.** Codex CLI 0.144.6 exposes stable hooks
  (`~/.codex/hooks.json`, event names identical to Claude's `~/.claude/settings.json`).
  Prefer hooks for live Codex sessions; keep the rollout-watching path (`CodexScan` +
  `CodexWatcher`) as a **fallback**, never the sole live source.
- **Preserve the user's config.** Hooks / statusLine in `~/.claude/settings.json` and
  `~/.codex/hooks.json` are edited by **additive merge only**, never overwrite, with a
  **timestamped backup first**. Never touch the user's Codex `notify` in `config.toml`.
- **Verify end-to-end.** Nothing is "done" until exercised with a **real live session**
  (Claude and/or Codex) in a terminal — card, state, tool, jump, approvals — not just a
  green build.
- **Git.** Work on `main`; `origin` is `taurinexd/meowtch` (public). Commit before
  handing work to another agent. Push is allowed — the repo has no other contributors —
  but never force-push, and never push a dirty or untested tree.
- **No telemetry, ever.** The only network traffic is the daily update check (explicit
  consent, `updateAutoCheck`) and the opt-in Claude usage probe. No analytics, no
  cloud backend — a deliberate difference from the original.
- **Releases.** `Scripts/make-release.sh` cuts everything (tests → app → EdDSA-signed
  `Meowtch.zip` → DMG → tag → GitHub release). The signing key lives in the Keychain
  ("Vedetta Update Signing") and can never be rotated without stranding shipped apps —
  its public half is compiled into `UpdateChecker.publicKey`. Bump `VERSION` first.
- **No Apple Developer account** (deliberate, zero-cost): the app is self-signed, not
  notarized. `install.sh` (`curl | sh`) is the friction-free channel — curl applies no
  quarantine, so Gatekeeper never appears. Keep it that way.

## Build & run
- `make app` from the **repo root** (not `App/`), then `open dist/Meowtch.app`.
- `make build` / `make test` — the Makefile `TESTFLAGS` work around a macOS 26 Command
  Line Tools quirk where `swift test` misses the Testing.framework paths.
- A stable self-signing identity **"Vedetta Dev Signing"** keeps TCC (Accessibility)
  grants alive across rebuilds.

## Layout
- `App/Sources/Vedetta` — the app: notch panel/UI, `EventDispatcher`, `EventServer`
  socket, `JumpService`, `VedettaSetup` (hooks/launcher), `UsageModel`/`CodexUsageProbe`,
  `RemoteBridge` (optional mirror of questions/plans to a local command).
- `App/Sources/VedettaKit` — shared model/parsers: `SessionEventReducer`, `SessionStore`,
  `TranscriptPeek`, `CodexScan`, `HookConfigurator`, `AgentSession`.
- `App/Sources/VedettaBridge` — the `vedetta-bridge` hook helper (reads the hook payload,
  captures terminal identity, relays to the socket; **source-agnostic**, `--source claude|codex`).
- `extensions/vscode` — the companion `terminal-focus` extension (jump/`/focus` only).
