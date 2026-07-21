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
| **Codex** | `CodexAppServerClient, CodexStdioAppServerClient, CodexRolloutFileEventMonitor, CodexRolloutIngressGate, CodexSessionIndexStore, CodexSessionWatcher, CodexTurnContextResolver, CodexHookTrustService, CodexResetSignalService` (9) | stack ibrido hook + rollout/index incrementali + app-server persistente | parità terminale raggiunta nel Pass 3; reset-signals cloud esclusi |
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
- `HookIngressRingBuffer` resta escluso; `HookIngressGate` **non era minore**: il test live ha dimostrato che connessioni detached possono consegnare `SessionStart` dopo `Stop`. Vedetta ora allega `capturedAt` nel bridge e rifiuta per-sessione le transizioni hook più vecchie (`6cc459b`).

## Verdetto Pass 1

Il **core è in parità** (notch, sessioni, approvals, questions, jump, socket). Il gap Codex rilevato qui è stato chiuso nel Pass 3. Restano sottosistemi separati dal supporto terminale richiesto: **Sound**, **Onboarding** e il blocco **privacy/display**; il DB storico Usage di VI è intenzionalmente escluso come analytics locale.

## Prossimi passi possibili (audit analysis, Pass 2)

- Deep-dive futuri, separati dal piano terminale: **Sound**, **Onboarding**, privacy/display.
- Verificare comportamenti fini del notch (espansione, glance, peek, collapse) contro VI a binario.
- Confermare le esclusioni fuori-scope o riconsiderarne qualcuna (es. privacy/display).

## Pass 2 — Deep-dive Usage/quota (2026-07-20)

**Verdetto: Claude usage corretto e completo; unico gap buildable = quota Codex.**

- **Struttura reale `rate_limits`** (dal binario Claude Code): `rate_limits.{five_hour, seven_day}.{used_percentage: 0-100, resets_at: epoch}`. **Solo due finestre** (nessuna terza tipo Opus-weekly — verificato). Il nostro `UsageModel` combacia (cerca `five_hour`/`seven_day`, `used_percentage`, `resets_at` epoch) e lo `strip` in `NotchView.topBar` mostra 5h/7d con % color-coded (rosso ≥80, arancio ≥50) + label reset. Fonte primaria = `statuslineCache` (`rl.json`), **la stessa di VI**.
- **Quota Codex (gap principale, buildable):** VI usa `CodexAppServerClient`/`CodexStdioAppServerClient` — si connette al **Codex app-server** (binario `codex`, WebSocket o stdio) e chiama il metodo `rateLimits` (`Codex app-server rateLimits ok`), con fallback ai `rate_limits` nei JSONL di sessione Codex (`Codex JSONL rate limits ignored: no usable snapshot`). Noi non l'abbiamo. → è il vero lavoro per la quota Codex nello strip.
- **Minori:** VI fa peek del notch quando una finestra supera una % soglia; notifica quando una finestra si resetta.
- **🚫 Fuori scope confermato:** `UsageIngestionDatabase`/`UsageRollupStore`/`usage_daily_rollups`/`UsageBehaviorDay/MonthFile` = **storico consumo** giornaliero/mensile (analytics), non serve allo strip live e va contro lo zero-telemetria.
- Nota: VI ha un backend cloud `api.vibeisland.app` (`/api/codex-reset-signals`, `/api/instances`, `/v1/licenses`) — per licensing/instances/reset-signals, fuori scope.

## Pass 3 — Codex terminal integration deep-dive (2026-07-21)

**Il piano (2026-07-16) diceva "Codex config non toccato / niente hook". È SUPERATO: Codex CLI 0.144.6 espone hook stabili.**

Prove:
- `codex --help` → flag `--dangerously-bypass-hook-trust`.
- `~/.codex/config.toml` → sezioni `[hooks.state]` (trust persistito per hook, per evento: session_start, permission_request, stop, post_tool_use, subagent_stop, user_prompt_submit).
- `~/.codex/hooks.json` **esiste già** e VI ci ha installato i suoi hook Codex: `'vibe-island-bridge' --source codex` su `PermissionRequest` (timeout 7200), `PostToolUse`, `SessionStart`, `Stop`, `UserPromptSubmit`, `SubagentStop`. **Formato e nomi evento IDENTICI a Claude** (`hooks: {NomeEvento: [{hooks:[{type:"command", command, timeout}], matcher?}]}`).
- Schema app-server conferma il sottosistema: `HookEventName`, `ConfiguredHookHandler`, `HookCompletedNotification`, ecc.

**Implicazione (correzione dell'audit Pass 1):** VI usa un ingresso ibrido, non una scelta fra hook e rollout. Gli hook sono la fonte real-time per lifecycle, identità terminale e approvazioni; i rollout aggiungono tool-start/detail, recupero di eventi mancanti e bootstrap delle sessioni già aperte. `session_index.jsonl` è autorevole per i rename; l'app-server lo è per usage e stato/trust degli hook.

### Matrice source-of-truth implementata

| Dato | Fonte primaria | Ruolo delle altre fonti |
|---|---|---|
| lifecycle, prompt/finale, approval, terminale | hook | rollout recupera solo completion mancante con guardia su turn/revision |
| tool-start, tool detail, chiamate parallele | rollout incrementale | `PostToolUse` conferma l'esito senza cancellare altri call ID |
| titolo conversazione | `session_index.jsonl` incrementale | primo prompt è solo fallback iniziale |
| usage, hook list/trust | app-server persistente | rate limits nel rollout sono last-resort |

Il coordinatore Codex è l'unico writer di `SessionStore`: impedisce a letture rollout lente di sovrascrivere hook più recenti, deduplica Stop/completion, correla thread/turn/tool ID e rimuove atomicamente sessione + terminal mapping quando un titolo tardivo rivela un worker interno.

### Esito implementazione

- Manifest VI riprodotto esattamente: sei eventi; timeout `7200` solo su `PermissionRequest`, `5` sugli altri; matcher vuoto solo su `PostToolUse`.
- Decoder tipizzato conserva gli ID Codex originali e normalizza gli alias shell senza loggare i payload.
- Tailer rollout e session index append-only, con cursore, partial-line buffer e reset dopo truncate/replace.
- Titoli rinominati aggiornati a caldo; filtri per `Codex Companion Task:` e metadati `task-worker`, inclusa riclassificazione tardiva.
- App-server persistente multiplexato per request ID, con idle shutdown, backoff e last-known-good usage.
- Routing approvazioni equivalente a VI: follow-focus, always-notch, always-terminal, native Codex; ogni errore/ambiguità lascia la decisione al terminale.
- Home Codex default/custom indipendenti; nessuna scrittura di `notify`, hash di trust o `[features] hooks=false`.
- UI card espone branch, model, permission mode e subagent parent-aware; Jump appare soltanto con host + identità processo/finestra verificabili.

Commit di implementazione: `fa0e818`…`a35e671` (più `025eeab` per la rimozione degli handler Codex obsoleti).

## Pass 4 — Verifica Claude terminal contro VI (2026-07-21)

Binario verificato: `/Applications/Vibe Island.app/Contents/MacOS/vibe-island`, SHA-256 `f2fda8a0ccf112d19fc7545510d52689be634238700c25c74211627b496f3371`. Le fonti usate sono strings/simboli del binario, manifest installato reale e comportamento del bridge; il Desktop Claude resta intenzionalmente fuori scope.

| Area | VI osservato | Vedetta dopo audit | Esito |
|---|---|---|---|
| manifest | 12 eventi; matcher `*` su Notification, PermissionRequest, PostToolUse, PreToolUse; timeout `86400` solo PermissionRequest | stesso descrittore source-specific | match |
| lifecycle | SessionStart, prompt, pre/post tool, compact, stop/failure, subagent, end | reducer copre gli stessi eventi e preserva root cwd | match |
| approval/question | risposta bloccante via `hookSpecificOutput.decision`, nessuna autorizzazione se il bridge non risponde | stessa shape; failure senza decisione | match |
| approvazioni native | default notch, toggle `deferClaudeApprovalsToNative` | aggiunto toggle identico nel menu; native restituisce `{}` | corretto in `00070fc` |
| configurazione | parser tollera commenti `//`, merge/rimozione marker-specific, statusline straniera viva preservata | parser JSON-with-comments aggiunto; merge atomico con backup | corretto in `00070fc` |
| terminal identity | TERM_PROGRAM/bundle/process ancestry/window, jump al terminale IDE | VS Code riconosciuto anche senza `__CFBundleIdentifier`, purché esista identità processo/finestra | corretto in `00070fc` |
| worker/desktop | Cowork/Desktop hanno watcher dedicati | esclusi per decisione di scope | intenzionale |

I mismatch terminali emersi dall’audit (commenti nelle settings, toggle native approvals, VS Code senza bundle identifier e ordine delle connessioni hook) hanno test di regressione. Il test live ha riprodotto l’ultimo: un `SessionStart` tardivo ribaltava uno `Stop`; `capturedAt` + stale rejection lo correggono sia nel reducer Claude sia nel coordinatore Codex. La suite finale conta 100 test in 17 suite.

## Stato lavori — progress (sessione 2026-07-20/21)

Tutto su `main` locale (nessun push). Commit principali:

| Commit | Cosa |
|---|---|
| `97ce721` | **Rispondere a Question dal notch** via hook `updatedInput.answers` (abbandonata l'iniezione nel terminale) |
| `ba09521` | Wizard multi-domanda (una alla volta, tab, progresso, Skip, ENTER→invia) |
| `5d8c266` | Self-cleanup del launcher orfano >5min (rimuove hook/statusLine, uninstall estensione) |
| `1e43e56` | Notch focalizzato sulla **singola card** su interrupt (approvazione/domanda) |
| `70ef134` | Questo audit (Pass 1 mappa 86 classi + Pass 2 Usage) |
| `774af5d` | **Quota Codex** nello strip via `codex app-server` (JSON-RPC `account/rateLimits/read`) |
| `d7e4b8b` | Fix: interrupt-resolve non chiude più il notch col cursore dentro |
| `52f5ae6` | Descrizioni opzioni domande non più troncate |
| `b0ec1b5` | **Switcher provider** nello strip (icone Claude a colori / Codex template bianco su nero, tap per ciclare) + font 10 + box reply allineato alle card |
| `0b2a08c` | Ignora SIGPIPE (una pipe rotta della probe Codex non abbatte più l'app) |
| `4fa32f5` | Fix hover: il notch si apre entrando dal bordo superiore dello schermo |
| `5e6ae47` | **M6 workaround**: card Codex live via rollout watcher (stato/tool/messaggi) — poi fix `deservesFullRow` (card Codex senza terminale) |

**Stato corrente:** implementazione Codex e correzioni Claude completate nel codice; verifica live e packaging finale documentati separatamente in `docs/verification/2026-07-21-codex-terminal-parity.md`.

## Verifiche note incrociate (per non riscoprire)

- **Risposta a domande** = hook `PermissionRequest` bloccato → `hookSpecificOutput.decision.updatedInput.answers` (record `{testo_domanda: label}`). VI non ha **nessuna** API di guida terminale (no CGEvent/TIOCSTI/sendText). Il picker nativo appare comunque nel terminale durante il blocco (specchio). Implementato in Vedetta (commit `97ce721`, `ba09521`).
- **Multi-domanda** = wizard una-alla-volta (`WizardQuestionView`); il terminale usa una tab-bar (`currentQuestionIndex`, chord Tab "switch questions", tab "✓ Submit"). Free-text/Skip esistono solo nel picker terminale (`type:"input"`, `response`), non nel notch di VI.
- **Self-cleanup launcher** orfano >5 min via `.orphaned` + JXA che rimuove hook/statusLine col marker (VI: marker `vibe-island`; noi: `vedetta`). Implementato (commit `5d8c266`).
