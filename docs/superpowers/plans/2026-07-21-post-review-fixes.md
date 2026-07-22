# Post-review fixes — 2026-07-21 — COMPLETATO

Esito della review dell'integrazione Codex (36 commit `a1733d0`…`c0e00de`) più le
4 note di Matteo. Ogni fix: implementazione + test + commit separato; verifica
end-to-end in coda. Suite finale: **141 test / 21 suite, verdi**.

## Bug maggiori

- [x] **B1 — Flip verde→blu su handoff (nota 1, Claude)** — `0ef6e3f`
  Il resume della continuation (anche `.handoff` scatenato da Stop) faceva
  `transition(.running)` incondizionato, sovrascrivendo il verde appena
  applicato; lo stale-guard congelava lo stato sbagliato. Ora
  `SessionStore.clearApprovalState` resetta solo se lo stato è ancora
  `.needsApproval`.

- [x] **B2 — `needsApproval` Codex senza ritorno + hijack del pannello (nota 2)** — `747c85d`
  PostToolUse ora pulisce l'approval deciso a terminale (Codex non ha
  PreToolUse: il tool eseguito È il segnale). `focusedSession` prende il
  takeover solo per interrupt azionabili nel notch (pending in ApprovalCenter
  o domanda in QuestionStore), mai per un bare `.needsApproval`.

- [x] **B3 — Rollout in ritardo ribalta lo Stop hook (nota 1, Codex)** — `44be85c`
  La logica di stato sottrae `ledger.hookFinalTurns` dagli `activeTurnIDs`:
  un turno chiuso dagli hook non conta più come attività live del file.

- [x] **B4 — Card blu che si scambiano di posto (nota 4)** — `12a34a1`
  Nuovo `AgentSession.stateChangedAt` stampato centralmente da
  `SessionStore.upsert`/`transition` al solo cambio di stato; l'ordinamento
  same-state usa quello, non `lastActivityAt`.

- [x] **B5 — Terminale ucciso, card che resta (nota 3)** — `622d4cd` + `d8662f7`
  Liveness sweep sul timer 15s: policy pura in VedettaKit + probe kernel
  (sysctl controlling-tty / kill(0)), rimozione solo su evidenza positiva.
  **Revisione dopo il primo giro live**: gli hook girano con pipe (tty quasi
  mai catturata) e `TerminalInfo.pid` è il bridge (morto per design) → il
  primo sweep rimuoveva sessioni vive. Ora: fallback writer marcato con flag
  esplicito (`isWriterFallback`); identità hook senza tty vive tramite
  chain[2] (agente) / chain[3] (shell) — agente uscito con tab aperta resta,
  tab uccisa rimuove.

- [x] **Bonus — mappa VI stale blocca l'adozione** (seconda causa della nota 2) — `d99f584`
  `VIMapImport.adopt == true` saltava `adoptRecentSessions` per sempre: con
  VI spenta la mappa congelata a ieri nascondeva le sessioni nuove a ogni
  restart (joshua-request). Ora la sweep transcript integra sempre la mappa.

## Rilievi minori

- [x] **M1** — `c250c42` — lo stale-guard registra comunque l'identità
  terminale (senza rebind del windowId); scarta solo la mutazione lifecycle.
- [x] **M2** — `75f1abe` — `OrderedJSONDocument`: le riscritture config
  preservano commenti `//`, ordine chiavi, raggruppamento a righe vuote e
  literal originali; riscrive solo ciò che il transform ha cambiato.
  Dry-run su copie dei config reali: `settings.json` round-trip
  byte-identical.
- [x] **M3** — `8575897` — `.withFractionalSeconds` (Codex stampa i ms).
- [x] **M4** — `9a67ae3` — i turni `anonymous-turn-*` non rigettano più
  l'apply del rollout.

## Verifica end-to-end (eseguita su app viva, build post-fix)

- [x] `make test` verde (141/21); `make app` + relaunch.
- [x] Claude reale (`claude -p` sotto pty): card → stati → SessionEnd; pty
      chiusa → card rimossa alla prima sweep.
- [x] Codex reale (`codex exec`): card via hook, timeline `running →
      waitingForInput`, **nessun flip** di ritorno; card rimossa post-exit.
- [x] B1 via socket (envelope bridge reali): PermissionRequest pendente +
      Stop → reply `{}` (handoff), stato resta `waitingForInput`.
- [x] B2 via socket: PermissionRequest Codex routed-to-terminal (reply
      immediata `{}`) → `needsApproval`; PostToolUse → `running`.
- [x] B4: ordine del dump identico tra snapshot distanziati con più card
      running; cambia solo alle transizioni di stato.
- [x] B5: fixture di processo uccise → card sintetiche rimosse dalla sweep;
      joshua-request (claude vivo su ttys009) sopravvive a restart + sweep.
- [x] M2: unit test + dry-run byte-identical sui config reali (copie).

## Round 2 — hover/animazione notch (stessa giornata) — `7cf62f0`

- [x] **Cooldown hover rimosso** — la riapertura era gated su un rect statico
  + cooldown 0.7s. Ora `NotchAnimation` definisce la curva UNA volta e la
  condivide: la view ci anima, il controller interpola il rect in volo della
  shape (i layout callback riportano solo gli endpoint) e l'hover-to-expand
  testa il cursore contro la shape REALE che si restringe. L'area già
  liberata non riapre mai; la shape ancora presente sì.
- [x] **Scatto a fine collapse** — la spring criticamente smorzata strisciava
  ~1.3s (misurato su video: -1px/frame per ~700ms) e SwiftUI la troncava con
  un clamp di -4px. Ora bezier ease-out fissa 0.6s (profilo VI misurato):
  ri-misurato frame-by-frame, delta monotoni -3,-2,-1,-1,0, zero salto
  finale; l'unmount del contenuto (0.65s) cade DOPO la fine dell'animazione.
- Strumenti: comando socket `setExpanded` (debug), telemetria opt-in
  `VEDETTA_ANIM_LOG`, pipeline screencapture -v + ffmpeg + misura del bordo
  inferiore della shape per frame.
- [x] Confermato a mano da Matteo: collapse fluido e riapertura immediata
  sul notch anche mid-settle (dopo `acee803`, che ha chiuso l'ultimo caso:
  enter perso nella regione sovradimensionata → poll cursore-vs-forma).

## Round 3 — jump Codex ai terminal tab (2026-07-22, confermato da Matteo)

- [x] Due terminali Codex hook-bound in VS Code (5 finestre aperte): entrambe
  le card jumpable con chain a 7 pid, zero writer-fallback; click → AX raisa
  la finestra giusta (non frontmost) + URI `/focus` all'estensione col
  pidChain → **tab esatto selezionato**, per entrambe. Jump Claude ok nello
  stesso giro. Card pre-hook senza processo vivo correttamente non jumpable.
- [x] Chiusura dei due tab → card rimosse dalla liveness sweep al primo giro
  (~5-15s), osservato via socket. Il `dump` ora espone il terminal binding
  (jumpable/tty/chain/writerFallback) per questa diagnostica.

## Round 4 — Settings window (2026-07-22) — `f0db85a`

- [x] Finestra Settings sidebar-style (anatomia VI da `copyscreens/settings`,
  chiavi defaults cross-checked nel binario). 7 pagine: General,
  Integrations, Notifications, Display, Sound, Usage, About — SOLO controlli
  wirati a comportamento reale, zero toggle fantasma.
- [x] Aperture: gear del notch, menu status bar ("Settings…", ⌘,), comando
  socket `openSettings` con deep-link per pagina.
- [x] Menu status bar ridotto a Show/Hide Panel · Settings… · Quit; tutte le
  voci operative (hook, approvals, AX, display, mute) migrate nei Settings.
- [x] Nuovi comportamenti wirati: Launch at Login (SMAppService), hover
  toggle/durata, auto-collapse toggle, peek dwell/enable, disable
  click-to-jump, volume suoni, visibilità/provider usage strip.
- Verifica: 146 test verdi; ogni pagina catturata a screenshot dalla build
  viva (deep-link socket) e confrontata con gli screenshot VI.

## Round 5 — rifiniture live + suoni completi (2026-07-22)

- [x] Recap nella colonna testo, colore standard, wrap al punto di troncatura
  delle altre righe (`82a226f`).
- [x] Bug `JSONValue` bool-bridging: quota Codex a 0% rigettata dal parser →
  switcher usage morto; fix con test sulla risposta reale 0.145 (`1905e24`).
- [x] Press feedback su speaker/gear/usage strip; icona mute composita
  (speaker+X) a ingombro fisso (`1905e24`, `82a226f`).
- [x] Suono di fine turno mancante + 3 nuovi eventi (Session Start, Task
  Error, Context Limit) + Task Acknowledge (default off); **silence rules
  per-evento** con preview in Settings → Sound (`5e72b1a`) → il punto
  "silence rules" di M7 è CHIUSO. Di M7 resta solo l'estetica card
  domande/wizard.
- [x] Hook audio personali di Matteo disattivati per il test (ripristino:
  `~/.claude/personal-sound-hooks.disabled.json`).

## Round 6 — domande Codex interattive (2026-07-22, confermato da Matteo)

- [x] Mirroring `request_user_input` dal rollout: card arancione, chirp,
  opzioni cliccabili col componente condiviso Claude (`193830b`…`0402f16`).
- [x] Risposta remota silenziosa via file channel + estensione 0.8.1
  (auto-submit sulla cifra; niente raise/URI; focus intatto).
- [x] Wizard multi-domanda sequenziale con progresso persistito nello store
  (sopravvive al collasso del notch — bug trovato da Matteo).
- [x] Approvals: default Always Notch per entrambi gli agenti; dropdown
  unificato Claude/Codex nei Settings.
- Bug rientrati durante i test: ⏎ extra che accettava i default; estensione
  attivata solo onUri (canale file mai partito); @State perso al collasso.

## Coda (segnalazioni in attesa)

- [x] **Hover post-jump** — dopo un collasso programmatico il tracking
  SwiftUI resta desincronizzato ("cursore dentro") e il primo ritorno sul
  notch non genera l'enter. Fix: watchdog di risincronizzazione post-collapse
  (poll 50ms, max 60s) che segue il cursore contro la shape e si spegne al
  primo evento hover reale. In attesa di conferma di Matteo sul gesto.

## Residui noti (non bloccanti)

- Il self-cleanup JXA del launcher (`VedettaSetup`) usa ancora
  JSON.parse/stringify: in quello scenario estremo (app rimossa da >5 min) i
  commenti dell'utente non sono preservati.
- `ledger.hookPromptTurns/hookFinalTurns` crescono per la vita della
  sessione (bounded dal numero di turni; irrilevante in pratica).
- La sessione Codex adottata da rollout senza writer vivo non ha binding →
  mai rimossa dalla sweep (comportamento conservativo voluto).
