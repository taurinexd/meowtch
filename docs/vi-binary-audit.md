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
| lifecycle, prompt/finale, approval | hook | rollout recupera solo completion mancante con guardia su turn/revision |
| terminale/jump | hook | per sessioni pre-hook, PID del writer del rollout (`lsof -F`) + ancestry processo |
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

## Pass 5 — Correzione audit Codex jump/origin (2026-07-21)

La dichiarazione precedente di parità Codex era incompleta: copriva il jump delle sessioni nate con gli hook già caricati, ma non quello delle sessioni Codex CLI già aperte. La card `codex-vedetta` ha reso visibile il gap: rollout e titolo erano presenti, ma non esisteva un terminal binding, quindi `SessionRowView` scartava il tap.

### Evidenza primaria dal binario VI

- Il modello di sessione VI contiene `codexRolloutPath` e `codexWriterPid`; la firma riflessa dell’update Codex riceve entrambi insieme a `cwd`, `tty`, `terminalBundleId`, `originator` e `threadSource`.
- Il binario contiene `CodexWriterInfo` e `WriterLookupOutcome`.
- Nello stesso blocco di codice sono presenti `/usr/sbin/lsof` e il formato field-oriented `-F`: VI associa il file rollout aperto al processo Codex che lo sta scrivendo.
- `JumpInput` contiene separatamente `codexThreadId`, `pid`, `tty`, `bundleId` e `ideWindowId`; il percorso comune è `JumpInput → JumpPlanner → IDE resolver`.
- Le stringhe `codex://threads/` e `CodexDesktopThreadFocus` appartengono al percorso Codex Desktop, esplicitamente fuori scope. Non sono necessarie per il terminale IDE.

La prova sul processo reale conferma la relazione usata da VI: il rollout `019f83c2…jsonl` è aperto in scrittura dal PID Codex `15557`; la sua ancestry arriva allo shell VS Code e infine a `com.microsoft.VSCode`.

### Correzioni Vedetta

- `CodexTerminalDiscovery` esegue un singolo snapshot `lsof -c codex -Fpn`, associa rollout→writer PID e costruisce l’ancestry fino all’IDE.
- Il binding fallback conserva il PID del writer, non un semplice flag “risolto”. Se una sessione viene ripresa e il writer precedente è terminato, il nuovo evento rollout ripete `lsof`, aggiorna PID e ancestry e rende nuovamente valido il jump. Un hook successivo conserva autorità e sostituisce il fallback con tty/window/process identity più precisa; i refresh rollout non possono sovrascriverlo.
- Il click resta un unico percorso condiviso Claude/Codex: una volta recuperato il terminal binding, entrambe le card eseguono lo stesso `JumpService` e collassano il notch.
- `session_meta.originator/source/thread_source` viene ora letto prima di creare la card. `Codex Desktop` e il companion interno `Claude Code` sono esclusi immediatamente, non solo dopo l’arrivo tardivo di un titolo; questo chiude anche la causa delle card fantasma transitorie.
- Il secondo confronto delle firme VI ha fatto emergere anche `origin`, `subagentKind`, `subagentParentThreadId`, nickname e role: ora vengono conservati sia dagli hook sia dal bootstrap rollout. In questo modo una sessione figlia nata prima degli hook mantiene relazione e dettaglio parent-aware, e un worker classificato da `subagent_kind` viene filtrato già al `session_meta`.

Il secondo scan ha corretto anche un errore nella prima patch: `codexWriterPid` era stato trattato come “rollout già risolto”, mentre nel modello VI è un’identità mutabile. Il caso resume ha ora test dedicati sia per il refresh fallback→fallback sia per la precedenza hook→fallback. Con l’evidenza oggi disponibile, lifecycle, prompt/finale, tool paralleli, approvazioni, rename, metadata, subagent, terminal identity e click/jump hanno una fonte e una fallback esplicite. Commit: `d6c5261`, `bf4479c`, `7941eba`.

## Pass 6 — Review post-integrazione + riparazione regressioni (2026-07-21)

Review indipendente dei 36 commit dell'integrazione Codex contro il binario VI,
innescata da 4 note live di Matteo (stati blu/verde in ritardo, card
"joshua-request" sparita, terminale ucciso che non rimuove la card, card blu che
si scambiano di posto). Dettaglio completo, con E2E, in
`docs/superpowers/plans/2026-07-21-post-review-fixes.md`. Cause radice trovate:

1. **Handoff che ribalta lo Stop** — la continuation di un'approvazione risolta
   altrove faceva `transition(.running)` incondizionato DOPO che Stop aveva
   applicato il verde; lo stale-guard (`6cc459b`) congelava l'errore, e
   `ec54a88` aveva rimosso la rete di sicurezza euristica che prima lo
   mascherava. Fix `0ef6e3f` (`clearApprovalState`, reset solo da
   `.needsApproval`).
2. **`needsApproval` Codex senza via di ritorno** — Codex non ha PreToolUse: se
   la decisione avveniva nel terminale (routing follow-focus), nessun evento
   puliva l'orange, e l'interrupt orfano sequestrava `focusedSession`
   nascondendo tutte le altre card (prima causa della "sparizione" di
   joshua-request). Fix `747c85d` (PostToolUse pulisce; takeover solo per
   interrupt azionabili nel notch).
3. **Mappa VI congelata che blocca l'adozione** — `VIMapImport.adopt == true`
   saltava per sempre `adoptRecentSessions`: con VI spenta, le sessioni nuove
   sparivano a ogni restart finché un hook non le ricreava (seconda causa di
   joshua-request). Fix `d99f584` (la sweep transcript integra sempre la mappa).
4. **File rollout indietro rispetto agli hook** — dopo Stop hook, il file senza
   `task_complete` riportava la card a blu. Fix `44be85c` (`hookFinalTurns`
   sottratti dagli `activeTurnIDs`).
5. **Ordinamento per attività** — ogni hook bumpava `lastActivityAt` e le card
   running si scavalcavano. Fix `12a34a1` (`stateChangedAt` stampato al solo
   cambio di stato, chiave di ordinamento same-state).
6. **Nessuna liveness** — VI segue la vita del terminale (mappa con `tty`,
   `lastKnownPid`, `codexWriterPid`); Vedetta non rimuoveva mai. Fix `622d4cd`
   + revisione `d8662f7`: gli hook girano con pipe (niente tty) e
   `TerminalInfo.pid` è il bridge morto per design → l'ancora giusta è il
   segmento chain[2] (agente) / chain[3] (shell); il fallback writer Codex ha
   ora un flag esplicito (`isWriterFallback`). Rimozione solo su evidenza
   positiva; agente uscito con tab aperta resta, tab uccisa rimuove.
7. **Minori**: identità terminale conservata anche da eventi stale (`c250c42`);
   timestamp Codex con millisecondi (`8575897`); turni anonymous che
   rigettavano l'apply (`9a67ae3`); riscritture config che preservano commenti
   `//`, ordine e literal via `OrderedJSONDocument` (`75f1abe`, round-trip
   byte-identical sul `settings.json` reale).

Verifica: 141 test/21 suite; E2E su app viva — sessione Claude reale sotto pty
(card → stati → rimozione alla sweep dopo la chiusura della pty), `codex exec`
reale (timeline `running → waitingForInput` senza flip), envelope bridge
sintetici via socket per i percorsi handoff/terminal-routing, dump-order
stabile con più card running.

## Pass 7 — Codex request_user_input (2026-07-22)

Codex 0.145 introduce `request_user_input` (domande con opzioni, attive in
Plan mode). Verifica dal binario Codex + test live:

- **Nessun evento hook per le domande**: la lista completa degli eventi del
  runtime hook Codex è `pre_tool_use, permission_request, post_tool_use,
  pre_compact, post_compact, session_start, session_end, user_prompt_submit,
  subagent_start, subagent_stop`. Un test live (monitor sul socket durante una
  domanda reale) conferma: zero hook.
- **`updatedInput` rifiutato**: il binario contiene "PermissionRequest hook
  returned unsupported updatedInput" — il canale-dati che per Claude ci fa
  rispondere alle AskUserQuestion è esplicitamente non supportato da Codex.
  Gli hook Codex possono solo allow/deny.
- La domanda È scritta nel rollout (`function_call request_user_input`, args
  con `questions[].question/options[].label`), e la risposta arriva come
  `function_call_output` a risposta data.

**Soluzione Vedetta** (oltre VI, che è pre-0.145): mirroring dal rollout
(card needsApproval + "Question" + opzioni) e risposta remota via estensione
VS Code 0.7.0 (`/answer`: individua il terminale esatto per ancestry e digita
`<numero>⏎` solo lì — mai tastiera globale). Multi-domanda: solo view+jump.
Migrare al canale hook il giorno in cui OpenAI espone un evento per lo user
input. Nota colta di passaggio: Codex supporta anche `pre_compact`,
`post_compact`, `session_end`, `subagent_start`, `pre_tool_use` — eventi che
il manifest VI non installa; possibile estensione futura del nostro manifest
(es. contextLimit sound anche per Codex).

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
- **Il self-cleanup di VI 1.0.41 è ROTTO** (scoperto disinstallandola, 2026-07-22): il ramo orphan del suo launcher muore con `unmatched "` (parse error zsh a riga 48, heredoc JXA) — non scrive mai il marker né esegue il cleanup. La disinstallazione ha richiesto pulizia manuale dei config (backup in `~/.vedetta/backups/*-pre-vi-uninstall`). Il launcher di Vedetta è verificato pulito con `zsh -n`. Da aggiungere: un parse-check del launcher nei test/build.
