# Post-review fixes — 2026-07-21

Esito della review dell'integrazione Codex (36 commit `a1733d0`…`c0e00de`) più le
4 note di Matteo. Ogni fix: implementazione + test + commit separato; verifica
end-to-end complessiva alla fine. Stato: `[ ]` da fare, `[x]` committato.

## Bug maggiori

- [ ] **B1 — Flip verde→blu su handoff (nota 1, Claude)**
  `EventDispatcher.handlePermissionRequest` fa `transition(.running)` incondizionato
  al resume della continuation (anche `.handoff` scatenato da Stop): sovrascrive il
  `waitingForInput` appena applicato e, con lo stale-guard del reducer, lo stato
  sbagliato resta fino all'evento successivo. Fix: reset a `.running` solo se lo
  stato corrente è ancora `.needsApproval` (helper puro in VedettaKit + test).

- [ ] **B2 — `needsApproval` Codex senza ritorno (nota 2, hijack del pannello)**
  PermissionRequest Codex instradata al terminale: il coordinator setta
  `.needsApproval` prima del routing e nessun evento lo pulisce (postToolUse è
  `break`, il rollout lo preserva). L'interrupt orfano sequestra `focusedSession`
  e nasconde tutte le altre card (è così che "joshua-request" è sparita).
  Fix: (a) coordinator pulisce `needsApproval → running` su `.postToolUse`;
  (b) `NotchView.focusedSession` prende il takeover solo per interrupt
  *azionabili* (pending in ApprovalCenter o domanda in QuestionStore).

- [ ] **B3 — Rollout in ritardo ribalta lo Stop hook (nota 1, Codex)**
  Dopo `Stop` hook, una lettura rollout col file indietro (manca `task_complete`)
  rimette `.running`. Il revision-guard protegge dall'interleaving, non dal file
  vecchio. Fix: la logica di stato sottrae `ledger.hookFinalTurns` dagli
  `activeTurnIDs` prima di decidere running/waiting.

- [ ] **B4 — Card blu che si scambiano di posto (nota 4)**
  `SessionStore.sort()` ordina per `lastActivityAt`, aggiornato a ogni hook.
  Fix: nuovo `AgentSession.stateChangedAt` (stampato centralmente da
  `upsert`/`transition` solo al cambio di stato) come chiave di ordinamento
  secondaria stabile.

- [ ] **B5 — Terminale ucciso, card che resta (nota 3)**
  Nessuna liveness sweep; VI tiene tty/pid per sessione (`session-terminals.json`,
  `lastKnownPid`/`codexWriterPid`) e li usa. Fix: policy pura in VedettaKit
  (sessione rimossa quando il terminale è *provatamente* morto) + collector di
  sistema (sysctl per pid → controlling tty dev vs `stat(tty).st_rdev`) sul
  timer 15s. Regole: hook-bound → morto se nessun pid della chain (bridge escluso)
  è vivo e attaccato al tty della sessione; Codex fallback (`tty == nil`) → morto
  se il writer pid è morto e il rollout è fermo da ≥60s. Nessuna identità → keep.

## Rilievi minori

- [ ] **M1 — Lo stale-guard del reducer perde l'identità terminale**
  Registrare il terminale (senza rebind del windowId) anche per eventi scartati.
- [ ] **M2 — La riscrittura config perde commenti `//` e ordine chiavi**
  Writer order/comment-preserving in `HookConfigFileStore` (merge del dizionario
  trasformato dentro il documento originale ordinato; literal scalari intatti).
- [ ] **M3 — `CodexRolloutTailer.date()` non parse i frazionali ISO**
  `.withFractionalSeconds` con fallback al formato secco.
- [ ] **M4 — Turni anonymous rigettano l'apply del rollout**
  Il guard su `currentTurnID` rigetta solo se il rollout espone turn id reali.

## Verifica end-to-end (alla fine)

- [ ] `make test` verde; `make app` + relaunch.
- [ ] Sessione Claude reale (`claude -p`) → card, stati, terminal identity.
- [ ] Sessione Codex reale (`codex exec`) → card via hook, stato blu→verde senza flip.
- [ ] Approvazione via socket `decide` + handoff simulato (envelope bridge sintetici):
      Stop dopo handoff non ribalta il verde (B1); postToolUse pulisce l'orange (B2).
- [ ] Kill del terminale → card rimossa entro una sweep (B5).
- [ ] Ordine `dump` stabile con più sessioni blu (B4).
- [ ] Config con commenti `//` + chiavi disordinate: merge preserva tutto (M2).
