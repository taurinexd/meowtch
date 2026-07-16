# Vedetta — replica open-source di Vibe Island

## Contesto

Vibe Island (https://vibeisland.app) è un'app macOS commerciale closed-source ($19.99) che usa il notch del MacBook come superficie di controllo per agent AI di coding: sessioni live nel notch, approvazioni senza cambio finestra, jump al terminale esatto. Il repo GitHub linkato **non contiene sorgente** (solo README + issue tracker), quindi "replicare" = **reimplementare da zero**. Matteo vuole una replica **ridimensionata** e **open-source pubblica**, nome scelto: **Vedetta**. Destinazione: `~/Code/vibeisland` (directory vuota, da rinominare `~/Code/vedetta` e inizializzare come repo git in M1).

Nota legale: reimplementazione funzionale legittima; nome/branding/asset propri; analisi dell'originale limitata a osservazione black-box (config deployati, file scritti, comportamento) — nessuna decompilazione, nessuna copia di codice.

## Scope

**Dentro (selezionato da Matteo):**
- Pannello notch con stato sessioni live (in esecuzione / attesa input / richiede approvazione / completata) + floating bar per display senza notch
- Agenti: **solo Claude Code + Codex**
- Card sessione: titolo = prompt reale, branch/worktree git, tool call in corso + modello, tempo trascorso, tracking subagent
- Approvazioni allow/deny dal notch + coda multi-sessione + navigazione da tastiera
- Domande multiple-choice (AskUserQuestion) visibili dal notch, risposta remota se fattibile
- Plan review con rendering Markdown
- Jump preciso: **solo VS Code** (terminale integrato/split esatto)
- Sound alerts 8-bit + sound pack custom
- Usage/quota tracking (Claude + Codex)
- Glance mode (status dot a pannello collassato)
- Auto-setup zero-config con backup, drift-check e self-healing
- Vincoli: **Swift nativo** (no Electron, <50MB RAM), **fully local** (zero cloud/account/telemetria — nemmeno il ping di trial che fa l'originale)

**Fuori:** SSH remote, Quiet Scenes, altri agenti/terminali, licensing/trial, localizzazione, device portal, auto-update Sparkle (v1: release GitHub manuali).

## Meccanismi osservati dall'originale (analisi black-box del 2026-07-16, macchina di Matteo)

Verificati installando Vibe Island 1.0.41 e diffando i config (baseline in conversazione):

1. **Approvazioni = hook `PermissionRequest`** in `~/.claude/settings.json`, `timeout: 86400`, sincrono: il bridge blocca finché l'utente decide dal notch (o scade → prompt normale nel terminale). Non serve PreToolUse per i permessi.
2. **Eventi usati (Claude)**: SessionStart, SessionEnd, UserPromptSubmit, PreToolUse, PostToolUse, PermissionRequest, Notification, Stop, StopFailure, SubagentStart, SubagentStop, PreCompact. Tutti con lo stesso comando; il payload stdin contiene `hook_event_name`.
3. **Pattern hook difensivo**: `/bin/sh -c '[ -x "$HOME/.vibe-island/bin/vibe-island-bridge" ] && "$HOME/.vibe-island/bin/vibe-island-bridge" --source claude; exit 0'` — app assente ⇒ no-op silenzioso, Claude Code mai rallentato né rotto. **Merge** con gli hook esistenti dell'utente (i suoi afplay sono rimasti intatti).
4. **Bridge = launcher zsh** in `~/.vibe-island/bin/` che risolve l'eseguibile vero dentro il bundle (`.app/Contents/Helpers/`), con fallback mdfind + cache; se l'app manca da >5 min → **self-cleanup completo** (rimuove hook e statusLine dai config via JXA embedded).
5. **Identità terminale catturata dal bridge al momento dell'hook** (l'hook gira nel contesto del terminale): tty, TERM_PROGRAM, bundleIdentifier, windowId, stato tmux. Persistita in `Application Support/vibe-island/session-terminals.json` (mappa sessione→terminale con anche firstUserMessage per il titolo card, lastAssistantMessage, currentTool, toolTarget, status). Cache `git-identity/` per cwd-hash (`{isGit, branch, repo}`) per l'indicatore branch. Env `CLAUDE_CODE_DISABLE_TERMINAL_TITLE=1` + cache `osc2-titles/` per matching via titoli finestra.
6. **Jump VS Code = estensione companion** `terminal-focus` (13 KB), auto-installata dall'app, attivata `onUri` (`vscode://vibe-island.terminal-focus/...`), zero comandi contribuiti. L'app richiede anche il permesso **Accessibility** (AX per raise finestre/terminali generici).
7. **Usage tracking Claude senza API**: statusLine script bash (installato in `~/.vibe-island/bin/`, user-customizable con sezione preservata) che estrae `rate_limits` dal JSON stdin di Claude Code → `cache/rl.json`, gated da preference `showUsage`.
8. **Codex: config NON toccato** (il `notify` di Matteo, già occupato da SkyComputerUseClient, è rimasto intatto) ⇒ monitoraggio Codex via watching di `~/.codex/sessions/*.jsonl` + detection processi (campo `codexOrigin` nella mappa). Niente multiplexer necessario.
9. **Layout runtime**: `~/.vibe-island/{bin, run/vibe-island.sock + .pid, cache/{git-identity, osc2-titles, rl.json}, data/usage/, custom-sounds/files, ssh/}`. Socket Unix in `run/`.
10. **Settings osservate nei defaults**: toggle per-agente, silence rules, pinning del display del notch (`screen.mode = pinned` + uuid), `childAgentNotificationTiming` (es. rootResponses), launch-at-login, palette della card benvenuto, contatori analytics locali (expands, jumps, approvals, sessioni, picchi di concorrenza). Update via Sparkle. Onboarding versionato (v3).
11. **Adapter multi-agente confermato**: stesso bridge con `--source gemini` e hook nel formato di Gemini CLI (BeforeAgent/AfterTool/…, timeout 5000) — pattern replicabile per ogni CLI.
12. **Verificato dal vivo durante il planning** (screenshot in `copyscreens/`): la richiesta di approvazione piano (ExitPlanMode) appare nel notch con i bottoni nativi di Claude Code (Manually Approve / Auto-accept Edits / Bypass Permissions) **più campo di risposta libera** ("Tell Claude what to change…") — la risposta testuale rientra nella sessione via canale PermissionRequest. Quindi approvazioni, piani E domande viaggiano tutti su quel canale con opzioni strutturate + free text. Anatomia card osservata: sprite pixel di stato (es. "?" = in attesa), titolo `<cartella> · <titolo sessione>`, ultimo messaggio troncato, badge agente + terminale, chip shortcut jump `^G ↗`, pulsante archivia, widget **Tasks** che renderizza la task list della sessione (done/in progress/open, completate collassate), badge rosso `BYPASS` per sessioni con permessi bypassati, età sessione, barra superiore "Tap to view usage limits" + icone volume/settings.

## Architettura Vedetta (rivista dopo l'analisi)

1. **App macOS nativa** — menu bar app (LSUIElement, SwiftUI + AppKit). Superfici: pannello notch (`NSPanel` non-activating, mai focus-stealing), floating bar fallback, menu di stato, finestra Settings. Stati UI: collapsed / expanded / approval / question / plan review / glance dot. Pinning del display configurabile.
2. **EventServer** — Unix domain socket in `~/.vedetta/run/vedetta.sock` (+ pidfile). Protocollo JSON line-based. Richieste bloccanti (PermissionRequest) tenute aperte fino a decisione.
3. **Hook-bridge** — helper eseguibile dentro il bundle (`Vedetta.app/Contents/Helpers/vedetta-bridge`, Swift, singolo binario) + launcher zsh in `~/.vedetta/bin/` che lo risolve (path fisso → mdfind → cache) e fa self-cleanup se orfano >5 min. Cattura identità terminale (tty, TERM_PROGRAM, bundle id, windowId, tmux) a ogni evento. Hook con guardia `[ -x … ] && …; exit 0`.
4. **ClaudeAdapter** — merge (mai overwrite) degli hook negli eventi elencati sopra in `~/.claude/settings.json`, backup timestampato prima di ogni scrittura, drift-check + self-healing a ogni avvio, uninstall pulito dal menu. `PermissionRequest` con timeout lungo per le approvazioni. StatusLine script user-customizable per harvest `rate_limits`. Arricchimento card dai transcript `~/.claude/projects/**/*.jsonl` (prompt, modello, tool, subagent).
5. **CodexAdapter** — nessuna modifica a `config.toml`: FSEvents su `~/.codex/sessions/**/*.jsonl` + detection processi per tty/terminale. Stati inferiti dagli eventi del transcript. Niente approvazioni remote per Codex in v1 (limite anche dell'originale).
6. **SessionStore** — state machine (running/waitingInput/needsApproval/done), mappa sessione→terminale persistita in `Application Support/Vedetta/session-terminals.json`, cache git-identity per cwd, timer.
7. **ApprovalQueue** — coda multi-sessione, Allow/Deny, shortcut tastiera, smart dispatch.
8. **QuestionBridge** — canale **validato empiricamente** (osservazione 12): le richieste arrivano via PermissionRequest con opzioni strutturate; la UI del notch replica i bottoni nativi (per piani: Manually Approve / Auto-accept / Bypass; per AskUserQuestion: le opzioni della domanda) + campo di risposta libera che rientra nella sessione.
9. **JumpService** — estensione VS Code companion propria (`vedetta.terminal-focus`, attivazione `onUri`, `vscode://…`), auto-installata; fallback Accessibility (AXRaise) via bundleId + windowId catturati dal bridge.
10. **UsageService** — Claude: `rate_limits` dallo statusline (zero API). Codex: da eventi rate-limit/token nei session JSONL (verifica in M7).
11. **SoundEngine** — suoni 8-bit sintetizzati + sound pack custom in `~/.vedetta/custom-sounds/`; silence rules per evento/agente.
12. **Error handling** — backup/ripristino config; parser JSONL tolleranti; hook no-op se app assente; self-cleanup orfano; uninstall dal menu.
13. **Privacy** — zero rete in v1 (nemmeno update check); eventuali statistiche solo locali e visibili all'utente.

## Linguaggio visivo (direzione estetica, asset propri)

Retro-terminal 8-bit coerente con i suoni: pixel-art, sfondo nero con starfield sparso, titoli in font pixelato, tipografia monospace, prompt-style `> … _` con cursore come elemento ricorrente. Icona app pixel-art propria (mai asset di Vibe Island). In fase di packaging (M8): DMG installer con background custom "drag to install" nello stesso stile.

L'onboarding dell'originale ha **animazioni curate** (non catturate): per Vedetta transizioni animate coerenti col linguaggio 8-bit — typewriter sui testi, starfield in parallasse, sprite pixel animati tra gli step. Se Matteo registra l'onboarding originale (⇧⌘5), estrarre frame con ffmpeg come riferimento di ritmo (senza copia 1:1).

## Onboarding (da replicare con identità propria)

Wizard multi-step: (1) welcome, (2) richiesta permessi (Accessibility per il jump), (3) "All Set" con review della detection — agenti rilevati con toggle individuali (detection da config/uso reale: `~/.claude/`, `~/.codex/`), terminali/IDE rilevati, toggle Launch at Login, (4) card di benvenuto condivisibile in pixel-art (variante "cartolina di vedetta/avvistamento", palette shuffle), (5) CTA finale con invito a riavviare le sessioni in corso (gli hook valgono solo per sessioni nuove).

**Riferimenti visivi**: Matteo raccoglie screenshot dell'originale (Settings, pannello espanso, approvazioni, plan review…) in **`copyscreens/`** dentro la repo — consultarli come riferimento UX durante M1/M3/M7 (ispirazione, non copia 1:1; la cartella resta fuori dal repo pubblicato via .gitignore).

## Struttura repo

```
vedetta/
├── App/                  # Swift Package puro (SwiftUI/AppKit) — niente .xcodeproj:
│   │                     #   builda con `swift build` (bastano le CLT); chi ha Xcode
│   │                     #   apre direttamente Package.swift
│   ├── Sources/Vedetta/  # app menu bar
│   └── Sources/VedettaBridge/  # vedetta-bridge (target eseguibile separato)
├── Scripts/make-app.sh   # assembla dist/Vedetta.app dal build SPM
├── extensions/vscode/    # estensione companion terminal-focus (TypeScript, onUri)
├── docs/superpowers/specs/  # design doc (questo contenuto, spec committata in M1)
├── LICENSE               # MIT
├── README.md
└── .github/workflows/    # CI: build + SwiftLint + test
```

## Milestone

1. **M1 — Skeleton**: rename dir → `~/Code/vedetta`, git init, spec committata, progetto Xcode, menu bar app, pannello notch con dati finti, floating bar fallback.
2. **M2 — Eventi Claude Code**: EventServer (socket) + bridge + launcher + ClaudeAdapter (merge/backup/self-healing/uninstall), card sessioni live reali con identità terminale.
3. **M3 — Approvazioni**: PermissionRequest bloccante, ApprovalQueue, suoni base, tastiera.
4. **M4 — Arricchimento**: transcript JSONL (titolo prompt, modello, tool, subagent), git-identity cache, tempo, glance mode.
5. **M5 — Jump VS Code**: estensione companion onUri + auto-install + fallback AX.
6. **M6 — Codex**: watcher `~/.codex/sessions` + detection processi + card/notifiche/jump.
7. **M7 — Rifiniture**: QuestionBridge (validazione empirica risposta remota), plan review Markdown, usage tracking (statusline rate_limits + quota Codex), sound pack custom, silence rules.
8. **M8 — OSS**: onboarding animato, icona/branding, README con screenshot, CI, DMG con background custom, (notarizzazione in fase successiva).

Ogni milestone: TDD dove sensato (parser, state machine, merge config), verifica empirica end-to-end prima di chiuderla.

## Verifica end-to-end

- Sessione Claude Code reale in VS Code → card nel notch con titolo/branch/stato corretti
- Tool call che richiede permesso → richiesta nel notch → Allow → il tool procede nel terminale (e Deny → bloccato)
- Due sessioni parallele → coda approvazioni corretta
- Click sulla card → focus sul terminale integrato VS Code esatto (via estensione)
- Stop sessione → suono + glance dot
- Sessione Codex → card con stato da session file
- Disinstallazione → config ripristinati, hook no-op
- Unit test parser/state machine/merge in CI
- Coesistenza con Vibe Island installata: gli hook di entrambe convivono (matcher separati); per il test comparativo tenere entrambe attive è utile, poi Matteo decide se disinstallare l'originale

## Questioni aperte

- Formato quota Codex nei session JSONL: verificare in M7.
- Payload esatto di PermissionRequest per piani/domande (struttura opzioni + free text): ricavarlo empiricamente in M3 da sessioni reali.
- Protocollo esatto bridge↔app (framing richieste bloccanti): definire in M2 (JSON line-based, request-id).
