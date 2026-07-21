# AGENTS.md — Vedetta

Vedetta is an open-source macOS menu-bar app (LSUIElement, SwiftUI + AppKit) that
turns the MacBook notch into a control surface for AI coding agents — **Claude Code
and Codex**: live session cards, in-notch approvals and questions, jump-to-terminal,
usage strip. It is a clean-room reimplementation of the commercial **Vibe Island**
(black-box analysis of its deployed config/behaviour only; own name, branding, assets).

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
- **Git is the handoff boundary.** Commit on `main` **locally; never push**. Commit the
  current patch before handing work to another agent.
- **No cloud / telemetry** (v1). Zero network, no analytics — a deliberate difference
  from the original.

## Build & run
- `make app` from the **repo root** (not `App/`), then `open dist/Vedetta.app`.
- `make build` / `make test` — the Makefile `TESTFLAGS` work around a macOS 26 Command
  Line Tools quirk where `swift test` misses the Testing.framework paths.
- A stable self-signing identity **"Vedetta Dev Signing"** keeps TCC (Accessibility)
  grants alive across rebuilds.

## Layout
- `App/Sources/Vedetta` — the app: notch panel/UI, `EventDispatcher`, `EventServer`
  socket, `JumpService`, `VedettaSetup` (hooks/launcher), `UsageModel`/`CodexUsageProbe`.
- `App/Sources/VedettaKit` — shared model/parsers: `SessionEventReducer`, `SessionStore`,
  `TranscriptPeek`, `CodexScan`, `HookConfigurator`, `AgentSession`.
- `App/Sources/VedettaBridge` — the `vedetta-bridge` hook helper (reads the hook payload,
  captures terminal identity, relays to the socket; **source-agnostic**, `--source claude|codex`).
- `extensions/vscode` — the companion `terminal-focus` extension (jump/`/focus` only).
