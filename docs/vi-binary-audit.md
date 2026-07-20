# Audit binario Vibe Island → Vedetta — Pass 1 (discovery)

> Data: 2026-07-20. Metodo: `strings` sul binario di VI (`/Applications/Vibe Island.app/Contents/MacOS/vibe-island`, ~26 MB), estrazione delle **86 classi Swift** (`_TtC10VibeIsland…`), cross-check contro il codice di Vedetta. Livello **discovery**: dai nomi classe + verifica nei nostri file. Ogni voce "⚠️ parziale" merita un deep-dive mirato (come fatto per la multi-domanda, che ha prodotto la scoperta di `updatedInput.answers`).
>
> Sorgenti: `scratchpad/vi-strings.txt` (VI), `scratchpad/cc-strings.txt` (Claude Code 2.1.215).

## ✅ Parità (core — ci siamo)

| Sottosistema VI | Nostro |
|---|---|
| `NotchPanel`, `NotchViewModel`, `NotchWindowController` | `NotchPanel` + `NotchPanelController` + `UI/NotchView` |
| `SessionStore`, `ConversationParser` | `SessionStore` + `TranscriptPeek` + `SessionEventReducer` |
| `SocketServer` | `EventServer` |
| `AppDelegate`, `EventMonitor`, `DiagnosticLogger` | `AppDelegate` + hover in `NotchPanelController` + log |
| Approvals, `SingleQuestionView` / `WizardQuestionView` | `ApprovalCenter` + `QuestionStore` + wizard multi-domanda |
| Jump (extension companion) | `JumpService` + estensione `vedetta.terminal-focus` |

## ⚠️ Parziale (in-scope, ma VI fa molto di più)

| Area | VI (classi) | Noi | Gap |
|---|---|---|---|
| **Sound** | `SoundManager, SoundSynthesizer, SoundPackPlayer, SoundPackStore, SoundSourceStore, SoundFilter, CustomSoundStore, SoundOutputDeviceObserver` (8) | `SoundEngine` (8-bit base) | sound pack, suoni custom, filtri, observer device output |
| **Usage/quota** | `UsageConsumptionService, UsageLimitService, UsagePricingSync, UsageRollupStore, UsageIngestionDatabase, UsageSQLiteConnection/Statement, UsageBehaviorRecorder`, `RemoteCodexUsageProbe`, `KimiUsageService` | `UsageModel` + `rate_limits` da statusline | consumption tracking, **DB SQLite**, limiti, pricing sync, quota Codex |
| **Codex** | `CodexAppServerClient, CodexStdioAppServerClient, CodexRolloutFileEventMonitor, CodexRolloutIngressGate, CodexSessionIndexStore, CodexSessionWatcher, CodexTurnContextResolver, CodexHookTrustService, CodexResetSignalService` (9) | `CodexScan` (scan sessioni base) | app-server client, rollout monitor, turn context resolver, hook trust |
| **Onboarding** | `Onboarding{CardWindow, DemoRunner, FullscreenWindow, ReadyWindow, WindowController, AnalyticsSession}` (6) | `OnboardingController` (base) | demo runner, multi-finestra, fullscreen |
| **Session naming** | `SessionNamingBrain, SessionNamingCoordinator, SessionNamingNativeWriter` | titolo da `ai-title`/`agent-name` nel transcript | "naming brain" (generazione/normalizzazione titolo) |
| **Settings/shortcut** | `SettingsWindow(Controller)`, `KeyboardShortcutManager`, `SilenceRulesStore` | settings parziali + monitor ENTER | pannello settings completo, shortcut manager (^G jump, nav tastiera), silence rules |

## ❌ Mancante (in-scope-ish, non iniziato)

- **Privacy/display** (candidato di valore per il prossimo blocco):
  - `ScreenObscuredDetector`, `ScreenCaptureDetector` — nasconde il notch durante screen-share/registrazione
  - `DisplaySleepObserver` — pausa quando il display dorme
  - `FocusModeDetector` + `FocusModeLogStream` — silenzia durante Focus mode macOS
- `ScreenSelector` — pinning display esplicito (scegliere su quale schermo vive il notch)
- `SessionAdmissionRulesStore` — regole su quali sessioni ammettere/mostrare
- `MemoryRestartGuard` — restart su memory pressure
- `NotificationWatcher` — watching notifiche macOS

## 🚫 Fuori scope (per il piano — esclusioni intenzionali)

- **SSH remote**: `SSHHostStore, SSHLocalClientResolutionCoordinator, SSHNetworkReachabilityObserver`
- **Licensing/trial**: `LicenseManager, LicenseWindow(Controller), TrialLeaseStore, TrialManager` — Vedetta è OSS/free
- **Update Sparkle**: `Update{UserDriver, ViewModel, Window, WindowController}` — release GitHub manuali
- **Analytics/telemetria**: `Analytics, UsageBehaviorRecorder`, `OnboardingAnalyticsSession` — zero telemetria per privacy
- **Altri agenti**: `Antigravity*, DeepSeek*, OpenCode*, Kimi*, GenericIntegrationStore` — solo Claude + Codex
- **Quiet Scenes / Cowork**: `QuietSceneMonitor`, `ClaudeCoworkWatcher`, `ClaudeDesktopCodeTitleIndex`
- Infra minori: `HookIngressRingBuffer`, `HookIngressGate` (buffering ingestione hook — noi abbiamo `EventServer` diretto)

## Verdetto Pass 1

Il **core è in parità** (notch, sessioni, approvals, questions, jump, socket). I gap reali in-scope sono nei sottosistemi *ricchi* dove abbiamo la versione base — **Sound**, **Usage** (VI ha un DB SQLite di consumo), **Codex** (VI ha integrazione profonda), **Onboarding** — e in un blocco **privacy/display** non ancora iniziato (nascondere il notch in screen-share, silenzio in Focus mode).

## Prossimi passi possibili (audit analysis, Pass 2)

- Deep-dive per sottosistema col metodo binario (come multi-domanda → `updatedInput.answers`): **Sound**, **Usage**, **Codex**, **Onboarding**.
- Verificare comportamenti fini del notch (espansione, glance, peek, collapse) contro VI a binario.
- Confermare le esclusioni fuori-scope o riconsiderarne qualcuna (es. privacy/display).

## Pass 2 — Deep-dive Usage/quota (2026-07-20)

**Verdetto: Claude usage corretto e completo; unico gap buildable = quota Codex.**

- **Struttura reale `rate_limits`** (dal binario Claude Code): `rate_limits.{five_hour, seven_day}.{used_percentage: 0-100, resets_at: epoch}`. **Solo due finestre** (nessuna terza tipo Opus-weekly — verificato). Il nostro `UsageModel` combacia (cerca `five_hour`/`seven_day`, `used_percentage`, `resets_at` epoch) e lo `strip` in `NotchView.topBar` mostra 5h/7d con % color-coded (rosso ≥80, arancio ≥50) + label reset. Fonte primaria = `statuslineCache` (`rl.json`), **la stessa di VI**.
- **Quota Codex (gap principale, buildable):** VI usa `CodexAppServerClient`/`CodexStdioAppServerClient` — si connette al **Codex app-server** (binario `codex`, WebSocket o stdio) e chiama il metodo `rateLimits` (`Codex app-server rateLimits ok`), con fallback ai `rate_limits` nei JSONL di sessione Codex (`Codex JSONL rate limits ignored: no usable snapshot`). Noi non l'abbiamo. → è il vero lavoro per la quota Codex nello strip.
- **Minori:** VI fa peek del notch quando una finestra supera una % soglia; notifica quando una finestra si resetta.
- **🚫 Fuori scope confermato:** `UsageIngestionDatabase`/`UsageRollupStore`/`usage_daily_rollups`/`UsageBehaviorDay/MonthFile` = **storico consumo** giornaliero/mensile (analytics), non serve allo strip live e va contro lo zero-telemetria.
- Nota: VI ha un backend cloud `api.vibeisland.app` (`/api/codex-reset-signals`, `/api/instances`, `/v1/licenses`) — per licensing/instances/reset-signals, fuori scope.

## Verifiche note incrociate (per non riscoprire)

- **Risposta a domande** = hook `PermissionRequest` bloccato → `hookSpecificOutput.decision.updatedInput.answers` (record `{testo_domanda: label}`). VI non ha **nessuna** API di guida terminale (no CGEvent/TIOCSTI/sendText). Il picker nativo appare comunque nel terminale durante il blocco (specchio). Implementato in Vedetta (commit `97ce721`, `ba09521`).
- **Multi-domanda** = wizard una-alla-volta (`WizardQuestionView`); il terminale usa una tab-bar (`currentQuestionIndex`, chord Tab "switch questions", tab "✓ Submit"). Free-text/Skip esistono solo nel picker terminale (`type:"input"`, `response`), non nel notch di VI.
- **Self-cleanup launcher** orfano >5 min via `.orphaned` + JXA che rimuove hook/statusLine col marker (VI: marker `vibe-island`; noi: `vedetta`). Implementato (commit `5d8c266`).
