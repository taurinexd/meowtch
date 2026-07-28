# Meowtch

**Your AI coding agents, watched from the notch — by a pixel cat.**

Meowtch (*meow* + *notch*) is a native macOS menu bar app that turns the
MacBook notch into a control surface for AI coding agents. See every
running session at a glance, approve permission requests without
switching windows, answer the agent's questions, review plans, and jump
back to the exact terminal that asked.

> The project codename is *Vedetta* — Italian for "lookout", the sentinel
> posted up high who spots what's coming and sounds the alert. You'll see
> that name in the code, the internal paths (`~/.vedetta`) and the bundle
> id; the cat on duty is Meowtch.

![Collapsed bar](docs/images/collapsed.png)

![Expanded panel](docs/images/expanded.png)

## Features

- **Live sessions in the notch** — running (pixel spinner), waiting for
  input (blinking bar), needs approval (blinking `?`), with real prompt
  titles, session names, git branch, current tool call and elapsed time
- **Approvals from the notch** — Claude Code permission requests are held
  open by a blocking hook while you decide; Allow/Deny without leaving
  what you're doing, with a multi-session queue
- **Questions & plan review** — AskUserQuestion options rendered as
  buttons, plans rendered as Markdown with Approve/Reject
- **Task list on the card** — the session's live task list, rebuilt from
  the transcript
- **Precise VS Code jump** — click a card, land on the exact integrated
  terminal (bundled companion extension, auto-installed)
- **Agents**: Claude Code (hooks, real-time) and Codex CLI (rollout files)
- **Usage strip** — 5h/7d quota with reset countdowns, harvested from the
  statusline with zero API calls
- **8-bit sound alerts** — synthesized in-app, custom packs via
  `~/.vedetta/custom-sounds/`, mute toggle
- **Session archive** — tray icon on hover hides a card persistently
- **Zero config** — detected CLIs are set up automatically with config
  backups; hooks are additive, idempotent, and self-neutralizing (if the
  app is gone they exit silently and never slow Claude Code down)
- **Auto-update** — checks GitHub Releases (only with your consent),
  verifies an EdDSA signature, swaps the app and relaunches
- **Private by default** — no cloud, no accounts, no telemetry. The only
  network traffic is the update check and the optional usage refresh,
  both off until you say yes

## Install

One command, no security dialogs:

```sh
curl -fsSL https://raw.githubusercontent.com/taurinexd/meowtch/main/install.sh | sh
```

Requires an Apple Silicon Mac. The script downloads the latest release,
installs it into `/Applications` and launches it — `curl` doesn't apply
macOS quarantine, so Gatekeeper never gets in the way.

**Manual alternative**: download `Meowtch.dmg` from
[Releases](https://github.com/taurinexd/meowtch/releases) and drag to
Applications. Meowtch isn't notarized (it's a free project with no Apple
Developer subscription), so a browser-downloaded copy is quarantined:
either approve it under System Settings → Privacy & Security → "Open
Anyway", or clear the flag yourself:

```sh
xattr -rd com.apple.quarantine /Applications/Meowtch.app
```

## How it works

Claude Code hooks invoke a tiny bundled bridge that forwards each event
(plus the terminal identity — the hook runs inside your terminal) to the
app over a Unix socket. Approvals ride the `PermissionRequest` hook: the
bridge holds the connection open until you decide from the notch and
replies with the documented `hookSpecificOutput` decision. Session titles,
messages and task lists are enriched from the transcript JSONL files with
bounded reads; Codex sessions are adopted from its rollout files without
touching `config.toml`.

Everything the app writes lives in `~/.vedetta/` (bridge launcher, socket,
cache, config backups) and `~/Library/Application Support/Vedetta/`.
"Remove Claude Code Hooks" in the menu restores your settings cleanly.

## Requirements

- macOS 14+ (Apple Silicon); a notch for the full effect, floating bar
  otherwise
- Swift 6 toolchain to build from source (Command Line Tools are enough —
  full Xcode not required)

## Building

```sh
make build   # swift build
make test    # swift test (200+ tests)
make app     # assembles dist/Meowtch.app (bridge + VS Code extension + icon)
make run     # build and launch
Scripts/make-dmg.sh  # dist/Meowtch.dmg
```

## Acknowledgements

Meowtch is an independent open-source reimplementation inspired by the
feature set of [Vibe Island](https://vibeisland.app), a commercial app by
its respective authors. Meowtch shares no code or assets with it and is
not affiliated with or endorsed by the Vibe Island team. If you want a
polished, supported product with a much broader integration matrix (26
agents, 20+ terminals, SSH remotes), go buy it — it's excellent.

## License

[MIT](LICENSE)
