# Vedetta

**Your AI coding agents, watched from the notch.**

Vedetta is a native macOS menu bar app that turns the MacBook notch into a
control surface for AI coding agents. See every running session at a glance,
approve permission requests without switching windows, and jump back to the
exact terminal that asked.

> *Vedetta* is Italian for "lookout" — the sentinel posted up high who spots
> what's coming and sounds the alert.

## Status

🚧 Early development — not yet usable. See
[`docs/superpowers/specs/`](docs/superpowers/specs/) for the design document.

## Planned features (v1)

- **Live sessions in the notch** — running / waiting for input / needs
  approval / completed, with real prompt titles, git branch, current tool
  call, model name and elapsed time
- **Approvals from the notch** — allow/deny Claude Code permission requests
  without leaving what you're doing, with a multi-session approval queue
- **Plan review** — full Markdown rendering before you approve
- **Precise terminal jump** — click a session, land on the exact VS Code
  integrated terminal that started it
- **Agents**: Claude Code and Codex
- **8-bit sound alerts** with custom sound pack support
- **Usage tracking** for Claude and Codex quotas
- **Zero config** — detected CLIs are set up automatically, with config
  backups, drift detection and self-healing
- **Fully local** — no cloud, no accounts, no telemetry. Nothing leaves your
  Mac.

## Requirements

- macOS 14+ (Apple Silicon)
- Swift 6 toolchain to build from source (full Xcode not required)

## Building

```sh
cd App
swift build
swift test
../Scripts/make-app.sh   # assembles dist/Vedetta.app
```

## Acknowledgements

Vedetta is an independent open-source reimplementation inspired by the
feature set of [Vibe Island](https://vibeisland.app), a commercial app by its
respective authors. Vedetta shares no code or assets with it and is not
affiliated with or endorsed by the Vibe Island team. If you want a polished,
supported product with a much broader integration matrix, go buy it.

## License

[MIT](LICENSE)
