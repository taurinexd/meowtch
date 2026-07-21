# Verifica session metadata toggle — 2026-07-21

Scope: una preferenza globale, futura-Settings-ready, per mostrare sulle sole
card complete Claude e Codex i metadati disponibili in ordine
`branch · model · reasoning effort`. Default disabilitato; permission mode e
placeholder esclusi.

## Verifica automatizzata

- Ciclo TDD osservato:
  - RED parser: `TranscriptPeek` e `CodexRolloutSnapshot` non esponevano effort.
  - GREEN parser: Claude prende l'ultimo effort main-session; Codex preferisce
    `turn_context.payload.effort` e usa
    `collaboration_mode.settings.reasoning_effort` come fallback.
  - RED propagazione: coordinator Codex e reducer Claude lasciavano
    `AgentSession.reasoningEffort` nil.
  - GREEN propagazione: rollout/transcript, bootstrap e refresh live convergono
    sul campo provider-neutral.
- `make test && make build && make app`: exit 0.
- Suite finale: **107 test in 17 suite**, 0 failure.
- `presentationMetadata` è testato per ordine esatto, omissione valori mancanti
  ed esclusione di `permissionMode`.
- La policy globale è testata per: off, full-row on, compact-row sempre off e
  metadata vuoti sempre nascosti.

## Verifica live sul bundle finale

- Stato iniziale UserDefaults:
  `defaults read app.vedetta.macos showSessionMetadata` → chiave assente, quindi
  default `false`.
- Bundle finale riavviato una volta; processo verificato dal path
  `dist/Vedetta.app/Contents/MacOS/Vedetta` e socket
  `~/.vedetta/run/vedetta.sock` presente.
- Con chiave assente, il pannello espanso non mostrava alcuna riga metadata
  sulle card complete; le righe compatte erano invariate.
- `defaults write app.vedetta.macos showSessionMetadata -bool true`, senza
  restart: tutte le card complete si sono aggiornate live. Casi osservati:
  - Claude con `feat/crm-ai-channel-widget-cli · high`;
  - Claude con `feat/crm-ai-channel-widget-cli · xhigh`;
  - Codex con il solo `medium` quando branch/modello non erano disponibili.
- Nessun placeholder è apparso e le card compatte non hanno mostrato metadata.
- `defaults delete app.vedetta.macos showSessionMetadata`, senza restart: le
  righe metadata sono scomparse live.
- Stato finale ripristinato esattamente: chiave nuovamente assente (default off).

## Esito

La stessa chiave stabile `showSessionMetadata` governa Claude e Codex da un
unico `@AppStorage` root. Il futuro pannello Settings potrà collegarsi alla
chiave senza modificare le card; nessun controllo temporaneo è stato aggiunto.
