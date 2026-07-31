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

**Soluzione Vedetta** (oltre VI, che è pre-0.145), verificata live da Matteo:
mirroring dal rollout (card needsApproval + "Question" + opzioni via il
componente condiviso con Claude) e risposta remota SILENZIOSA via estensione
VS Code 0.8.1: il tap scrive un file in `~/.vedetta/run/commands/`, ogni
finestra VS Code lo osserva (activation onStartupFinished) e solo l'istanza
che possiede il terminale digita la CIFRA — niente URI, niente raise, il
focus dell'utente non si muove. Lezioni misurate sul campo: (1) il picker
TUI auto-submitta alla cifra — un ⏎ extra fa accettare il default della
domanda successiva; (2) il wizard multi-domanda avanza localmente
(il rollout non registra nulla tra le domande) e il progresso vive nello
STORE di sessione, non in view @State: deve sopravvivere al collasso del
pannello (pattern QuestionStore di Claude). Migrare al canale hook il
giorno in cui OpenAI espone un evento per lo user input. Nota colta di passaggio: Codex supporta anche `pre_compact`,
`post_compact`, `session_end`, `subagent_start`, `pre_tool_use` — eventi che
il manifest VI non installa; possibile estensione futura del nostro manifest
(es. contextLimit sound anche per Codex).

## Pass 8 — Multi-account Claude: refresh OAuth e "follow the slot" (2026-07-24)

Territorio oltre VI (che è single-account). Problema partito da un bug visto
live da Matteo: dopo uno switch globale Tools→Tech, la card di Tools prima
mostrava i numeri di Tech (misattribuzione, fixata in `c0f4a27`) e poi si
sarebbe comunque congelata: **nessuno rinnova il token dell'account non
attivo** (access token TTL ~8h) e la probe dichiarava "never refreshes".
Un primo tentativo (`e337041`, enforcer che ri-pinnava lo slot) è stato
scartato: riscrivere un token vecchio sopra uno appena ruotato slogga i
terminali. Design definitivo — lo slot si SEGUE, mai combattuto (semantica
/login):

- **Refresh grant verificato live**: `POST https://api.anthropic.com/v1/oauth/token`
  con `{grant_type:"refresh_token", refresh_token, client_id}` →
  `access_token, refresh_token, expires_in (28800), refresh_token_expires_in,
  account, organization`. Endpoint e client id (`9d1c250a-e61b-44d9-88ed-5944d1962f5e`)
  estratti dal binario CLI 2.1.218 (la base è **api**.anthropic.com — la
  letteratura community su console.anthropic.com è datata).
- **`ClaudeTokenRefresher`**: rinnova SOLO account che non possiedono lo slot
  (Vedetta è l'unica proprietaria di quelle catene) e SOLO a token scaduto
  (mai ruotare una catena viva); write-back con guardia se l'item è cambiato
  durante la chiamata. Merge puro in `ClaudeCredentialRefresh` (VedettaKit,
  testato): aggiorna i 4 campi token e preserva tutto il resto del blob.
- **`AccountSwitcher.reconcileSlot()`** (ogni tick da 60s): se lo slot
  diverge dal mirror dell'account attivo, identifica il proprietario via
  `/oauth/profile` e ADOTTA — cattura la credenziale nel suo item namespaced
  (uno switch futuro non ripristina mai un refresh token ruotato) e, se il
  proprietario è un altro account registrato, sposta il puntatore attivo
  come fosse uno switch (un `/login` manuale viene quindi seguito, non
  annullato). Slot non identificabile (`claude.slotUnidentified`): mai
  toccato, mai catturato.
- **Attribuzione**: il locator ora ragiona per possesso — il proprietario
  dello slot lo legge per primo; chi non lo possiede legge SOLO il suo item
  namespaced (via il fallback che misattribuiva). `rl.json` (statusline del
  config dir default) è attribuito al proprietario dello slot, con guardia
  `claude.defaultSlotSwitchedAt` sui push precedenti all'handover — le
  sessioni post-switch alimentano il push dell'account switchato in tempo reale.

Verificato live (2026-07-24, switch Tools→Tech attivo): token Tools
forzato a scaduto → l'app lo ruota da sola in <60s e la card torna viva
(`origin: pull`, 7d 100% suo reale); Tech `origin: push` dall'rl.json delle
sessioni correnti; slot riserializzato (stessi token, byte diversi) →
reconcile identifica l'account secondario e rispecchia. Non ancora esercitato con utente:
l'adozione di un `/login` manuale verso un ALTRO account (ramo
`recordHandover`, stesso codice dello switch).

## Pass 9 — Card risorta blu dopo un restart (2026-07-24)

Bug visto live da Matteo: card `flow-issue` sparita dal notch dopo un
riavvio dell'app, poi ricomparsa BLU a sessione ferma. Ricostruzione
empirica (transcript da 19.4MB + snapshot byte-exact delle finestre di
TranscriptPeek):

- **Sparizione**: il guard di `adoptRecentSessions` accettava solo
  `firstUserPrompt || sessionName`. Su transcript enormi la head (128KB)
  non arriva al primo prompt e il marker `/rename` sta oltre (qui a byte
  473k); l'`aiTitle`/`agentName` nel tail c'era ma non veniva considerato
  → sessione scartata al bootstrap. Fix: basta un titolo qualsiasi
  (`|| aiTitle != nil`).
- **Ricomparsa blu**: la CLI genera l'`away_summary` MINUTI dopo lo Stop
  (qui alle 17:25:51, Stop alle 17:20:21) via sidechain, che emette hook
  Subagent. La creazione lazy del reducer nasceva `state: .running` per
  QUALSIASI evento; l'evento marca la sessione in `liveEventIds`, che
  disattiva l'euristica correttiva mtime → blu bloccato fino al prossimo
  evento di lifecycle. Fix: la creazione lazy da eventi di bookkeeping
  (SubagentStart/Stop, Notification) nasce `waitingForInput`, e il
  ghost-guard li copre (senza contenuto niente card).

Nota strutturale colta di passaggio: gli hook della CLI restano attivi
anche a sessione idle (recap sidechain, notification) — ogni evento bumpa
`lastActivityAt`, quindi il badge età può ringiovanire senza attività
visibile dell'utente.

## Pass 10 — Pubblicazione, rebrand Meowtch, auto-update (2026-07-28)

- **Brand**: l'app è **Meowtch** per l'utente; *Vedetta* resta il nome in
  codice (target, bundle id `app.vedetta.macos`, eseguibile, `~/.vedetta`,
  identità di firma). Regola in AGENTS.md: mai convertire i riferimenti
  interni — portano i grant TCC e gli hook già installati.
- **Repo pubblica**: `github.com/taurinexd/meowtch`, storia completa
  (gitleaks pulito; allowlist per i STORE_KEY dei ballot di branding).
  CI verde su macos-15. **Minuti Actions**: verificato sul report per-run
  (`/actions/runs/<id>/timing`) che una repo pubblica riporta
  `billable.MACOS.total_ms: 0` — i runner standard non consumano quota.
- **Credenziali git**: il helper globale `osxkeychain` restituiva
  `matteo-webgas` e il push del tag falliva con 403. Risolto **solo a
  livello di repo** (`credential.https://github.com.helper` = `!gh auth
  git-credential`), senza toccare la config globale usata dalle repo
  Webgas. Il token `taurinexd` ha richiesto lo scope `workflow` per
  poter pushare `.github/workflows/`.
- **Installazione senza attrito**: `install.sh` via `curl | sh`. Verificato
  end-to-end da zero: nessun attributo `com.apple.quarantine` sul bundle
  installato ⇒ **nessun dialogo Gatekeeper**, nessuna notarizzazione.
- **Auto-update**: check giornaliero su GitHub Releases (consenso
  esplicito), firma EdDSA verificata PRIMA di scompattare, validazione
  bundle id/versione/codesign, swap con ripristino del bundle precedente
  su qualunque errore, relaunch. Chiave privata nel Keychain ("Vedetta
  Update Signing"), pubblica compilata in `UpdateChecker.publicKey`:
  **non rotabile** senza spiaggiare le app distribuite.
- **Bug trovato dalla verifica e2e (v0.1.0 → fix in v0.1.1)**: dopo lo
  swap il successore bindava il socket, poi la teardown dell'istanza
  uscente ne faceva `unlink` → nuova app in ascolto su un inode
  irraggiungibile, **ogni hook falliva in silenzio** fino a un riavvio
  manuale. Fix doppio: `stop()` rimuove il file solo se è ancora quello
  creato da quell'istanza (dev+ino registrati al bind), e il server
  ri-binda al tick periodico se il suo file è sparito (guarisce anche gli
  update che partono da build col bug, entro 15s).
- Verificato dal vivo: 0.0.9 → 0.1.1 in-app, socket sopravvissuto
  (client reale connesso, 12 sessioni), TCC Accessibility ancora
  concessa, launcher ripuntato su `/Applications/Meowtch.app`.

## Pass 11 — Approvare un piano dal notch non arrivava (2026-07-29)

Sintomo (Matteo): «in plan mode la detection delle scelte non è rilevata
correttamente». La card `ExitPlanMode` compariva, ma premere **Approve**
non produceva nulla: il terminale continuava a chiedere.

**Causa** — estratta dal binario del CLI 2.1.220 e confermata dal vivo.
Alcuni tool dichiarano `requiresUserInteraction()`; per quelli il gestore
degli hook fa:

```js
if (!_.updatedInput && e.requiresUserInteraction?.()) return null
```

cioè **scarta un `allow` privo di `updatedInput`** e ricade sul prompt
nativo. `ExitPlanMode.requiresUserInteraction()` → `true` (falso solo in
modalità team, `o_()`); `AskUserQuestion` idem. Il `deny` invece passa
sempre — ecco perché *Reject* funzionava e *Approve* no.

Non era una regressione nostra: la risposta "allow nudo" è sempre stata
così, e la strada che già funzionava (le Question) rispondeva con
`updatedInput.answers` senza che il legame fosse capito. Fix: quando il
tool è nella lista di quelli interattivi, l'`allow` **rimanda indietro il
`tool_input` ricevuto** (`PermissionDecision.claudeReply`, testata). La
lista resta corta e verificata di proposito: allegare un `updatedInput`
fa rivalutare le regole di permesso sull'input, quindi una deny rule
dell'utente potrebbe scavalcare un allow appena dato dal notch.

Altre cose apprese, da non riscoprire:

- Il **piano non è più nel prompt**: `ExitPlanMode` non ha più il campo
  `plan` nello schema (il modello scrive su `~/.claude/plans/<slug>.md`).
  Il CLI però **inietta** `plan` + `planFilePath` nel `tool_input` prima
  della catena dei permessi (`Mid = Map([["ExitPlanMode", {"plan",
  "planFilePath"}]])`), quindi la card `.plan` continua a ricevere il
  markdown. Verificato sui transcript reali.
- `answers` accetta **sia stringa sia array** (`E.preprocess(... e.join(", "))`):
  il formato array che usiamo resta valido.
- Il prompt nativo del terminale viene disegnato **in parallelo** all'hook
  bloccato, non dopo: vederlo a schermo non significa che la nostra
  decisione sia stata scartata. Il discriminante è cosa succede *dopo*
  aver deciso dal notch.
- `claude -p` non espone `ExitPlanMode`: per riprodurre serve una
  sessione **interattiva** (harness pty in `scratchpad/planloop.py`).

Verifica A/B dal vivo, stesso harness, cambia solo il build: con 0.1.1 la
card arriva, si approva e non succede nulla (`calc.py` intatto, la TUI
resta sul suo prompt); col fix il CLI stampa `Allowed by PermissionRequest
hook` → `User approved Claude's plan` e la sessione passa
all'implementazione.

**Formattazione del piano** (stessa sessione). La card mostrava `#`, `##`,
`>` e i trattini come testo grezzo: `AttributedString` con
`.inlineOnlyPreservingWhitespace` interpreta **solo la sintassi inline**,
mai i blocchi. Aggiunto `PlanMarkdown` (parser puro, testato) +
`PlanMarkdownView`: titoli, citazioni, elenchi puntati e numerati (i numeri
originali si conservano — in un piano sono contenuto), blocchi di codice
recintati, righe orizzontali; il testo di ogni blocco continua a passare
per `AttributedString`, quindi grassetto/corsivo/codice inline reggono
anche dentro un titolo o una voce di elenco. La `ScrollView` ha ora
`.defaultScrollAnchor(.top)`: senza, un piano lungo si apriva a metà
nascondendo il proprio titolo. Verificato a schermo.

⚠️ **Nota operativa dolorosa**: durante la verifica ho pulito le sessioni
di prova con `pkill -x claude` e ho ucciso **tutte** le sessioni Claude
Code di Matteo. L'harness pty va terminato per PID (`pgrep -P <harness>`),
mai per nome di processo: `claude` è anche ciò con cui l'utente lavora.

## Pass 12 — Remote Bridge: review e messa in sicurezza (2026-07-30)

Un altro agente ha aggiunto il **Remote Bridge** (commit `e94caef`): le
domande e le approvazioni di piano vengono specchiate a un **comando
locale** scelto dall'utente (JSON su stdin), e una risposta lasciata in
`~/.vedetta/run/remote-answers/<id>.json` vale come un click nel notch.
Vedetta resta l'arbitro unico: chi risponde per primo vince, all'altra
superficie arriva un evento `resolved`. L'impianto era buono — logica pura
in `RemoteBridgeLogic` con test, off di default, scrittura atomica lato
notifier — ma la review ne ha trovati quattro difetti, tutti corretti qui.

**1. Un notifier che muore abbatteva l'app.** La notify scriveva sullo
stdin del figlio con `FileHandle.write(_:)`. Se il comando esce prima di
leggere (shim rotto, interprete assente), la pipe è spezzata; SIGPIPE è
ignorato da `main.swift` (commit `0b2a08c`), quindi non arriva il segnale
ma Foundation solleva una `NSException` ObjC che Swift non può catturare →
`abort()`. Riprodotto in isolato: exit 134 dentro
`-[NSConcreteFileHandle writeData:]`. Fix: variante lanciante
`write(contentsOf:)` e spawn su una coda dedicata, fuori dal main thread.
Verificato dal vivo forzando la pipe rotta con un payload più grande del
buffer (200 KB) e un notifier che chiude stdin: `notify failed`, app viva.
**Regola generale**: con SIGPIPE ignorato, ogni `FileHandle.write(_:)` su
una pipe è un crash in attesa — usare sempre la variante `throws`.

**2. Il piano arrivava senza il piano.** Il payload usava
`toolDetail ?? toolName`, ma per `ExitPlanMode` il `detail` è sempre `nil`
(si ricava da `command`/`file_path`/`description`, e il `tool_input` di un
piano contiene solo `plan` + `planFilePath`, cfr. Pass 11): da remoto si
leggeva `ExitPlanMode` e basta, cioè si approvava alla cieca. Ora il
payload porta `title` (prima intestazione utile, via `PlanMarkdown`) e
`body` (markdown troncato a 3000 caratteri su confine di riga — Telegram
taglia a 4096).

**3. L'id di una domanda era il session id.** Una risposta remota passa da
un umano e può tornare minuti dopo: se nel frattempo la sessione ha
cambiato prompt, la scelta veniva applicata **alla domanda sbagliata**, in
silenzio. Ora l'id è `<sessionId>.<digest>` dove il digest sono 4 byte di
SHA-256 di prompt+opzioni; `apply` rifiuta ciò che non combacia e il diff
emette `resolved`+`new` quando il contenuto cambia nella stessa sessione.
Verificato: id alterato → `stale or invalid`, id giusto → applicata.

**4. Configurazione solo al lancio.** Il bridge leggeva la chiave una
volta sola. Ora la segue a caldo: `UserDefaults.didChangeNotification` per
le modifiche dalla UI, **più un poll da 5s** perché quella notifica non
viene postata per un `defaults write` fatto da un terminale (verificato:
non arriva). E la feature ha una casa visibile — **Settings → Integrations
→ Remote Bridge**, in fondo alla pagina, con campo comando, stato e
avviso su cosa esce dalla macchina.

**5. «notify sent» non significava consegnato.** Emerso durante la verifica
live: il log diceva `notify sent: new plan-2` e su Telegram non arrivava
nulla. La notify buttava via exit code e stderr del comando, quindi
registrava un successo che era solo «la write su stdin è riuscita» — il
gateway rispondeva `disabled` (il suo kill-switch `remote_questions` era a
`false`) e nessuno poteva saperlo. Ora si attende l'uscita del processo e
un exit ≠ 0 finisce nel log con i primi 400 caratteri di stderr; la coda
di spawn è diventata concorrente perché ora si aspetta davvero.

Contorno: il log ruota a 256 KB (una generazione), il payload non viene
più ricostruito tre volte per riga di log, e il contratto del file di
risposta (**scrittura atomica**: temp con punto + rename) è ora scritto
nella docstring di `parseAnswer` — un `.json` che non parsa viene scartato,
non ritentato.

**6. «Quale finestra sta chiedendo?»** (chiesto da Matteo davanti al primo
messaggio riuscito). Il payload passava il session id nudo, un UUID: dal
telefono non si capiva quale delle sessioni aperte stesse parlando. Ora
`session` è un'etichetta leggibile — `vedetta · Fix del bridge`, cioè
cartella di progetto · nome della sessione (`sessionLabel`). L'app che
ospita il terminale è stata provata e poi **scartata su indicazione di
Matteo**: sapere che è VS Code non restringe nulla, sono le due finestre
sullo stesso progetto a doversi distinguere, e per quello serve il nome
sessione. L'UUID resta disponibile come campo `sessionId`.

**Contratto v4 (2026-07-31)** — le opzioni delle domande viaggiano come
oggetti `{"label", "detail"}` invece che come stringhe: `QuestionStore`
parsa già la descrizione di ogni scelta e `QuestionSnapshot` la buttava
via, così dal telefono si sceglieva alla cieca (in AskUserQuestion la
parte decisionale sta spesso nella descrizione, non nell'etichetta). Ogni
`detail` è condensato a 300 caratteri su una riga sola: il messaggio
Telegram ha un tetto di 4096 e il gateway ci mette anche titolo, elenco e
intestazione. Un'opzione senza descrizione resta `{"label"}` nudo, e un
ricevitore che legge solo `label` continua a funzionare — per questo
l'estensione non è breaking. Il digest dell'id ora include anche le
descrizioni: due domande con le stesse etichette ma significati diversi
sono domande diverse.

**Verifica live (2026-07-30)**: sessione Claude reale in plan mode via
harness pty → card nel notch → messaggio Telegram con titolo e corpo del
piano → **tap "Approva" dal telefono di Matteo** → `applied remote
decision for plan-1: approve` → il CLI stampa `User approved Claude's
plan` e prosegue → `resolved` → messaggio ritirato. È la prima volta che
il ramo piano gira end-to-end. Verificati anche, con envelope sintetici:
pipe rotta (app viva), impronta stale (rifiutata) e corretta (applicata),
accensione/spegnimento a caldo.

Controparte: `~/Code/matt-ai` (gateway OpenClaw/Telegram) si è già
allineata al contratto v2 (commit `6239199`: id con impronta, `body` del
piano, shim EPIPE-safe). Il contratto in una riga: `{event: new|resolved,
id, kind: question|plan, title, options?, body?, session}`.

⚠️ **Nota operativa**: per esercitare la pipe rotta ho iniettato una
domanda con un'opzione da 200.000 caratteri — la card ha invaso il notch
finché non è stata risolta. Gli envelope sintetici vanno tenuti di
dimensioni plausibili: il notch non impone un tetto all'altezza delle
opzioni.

## Stato verifiche e packaging (2026-07-24, fine giornata)

- **Multi-account**: verificato e confermato; resta solo l'adozione di un
  `/login` esterno, che Matteo eserciterà quando gli servirà davvero.
- **Branding task 9**: confermato da Matteo tranne la GIF custom (da provare).
- **DMG**: buildato con `scripts/make-dmg.sh` e verificato visivamente
  (starfield, gatto, freccia pixel, "> drag to install _", posizioni ok
  dopo la conversione UDZO). `dist/` resta fuori da git.
- **Parse-check script generati**: template estratti in
  `RuntimeScripts` (VedettaKit) e coperti da test `zsh -n`/`bash -n` —
  la guardia contro il destino del launcher rotto di VI 1.0.41.
- **Pubblicazione**: la repo online sarà privata, su account GitHub
  personale di Matteo; rimandata a data da destinarsi (M8 in attesa).

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
