# Verifica terminal integration — 2026-07-21

Scope: Codex CLI e Claude Code in terminali IDE. Vibe Island 1.0.42 è la source of truth; Claude/Codex Desktop, SSH, licensing e telemetria sono esclusi.

## Baseline e build

- VI binary SHA-256: `f2fda8a0ccf112d19fc7545510d52689be634238700c25c74211627b496f3371`.
- Test pre-live: 98 test in 17 suite, tutti passati.
- Il live test ha scoperto una race di ordine `SessionStart`/`Stop`; fix `6cc459b` con RED/GREEN dedicati per Claude e Codex.
- Verifica finale: 100 test in 17 suite, tutti passati; build debug e release package exit 0.
- Bundle: firma `Vedetta Dev Signing`; `codesign --verify --deep --strict` passato.
- Processo verificato dopo il package finale: PID 66979; socket Unix pronto.

## Matrice automatizzata

| Requisito | Evidenza |
|---|---|
| sei hook Codex VI esatti | `HookConfiguratorTests` |
| merge/rimozione indipendenti e backup | `HookConfigFileStoreTests`, `HookConfiguratorTests` |
| payload Codex tipizzati e fallback safe | `CodexHookEventTests`, `CodexApprovalPolicyTests` |
| rollout incrementale/parallel-safe | `CodexRolloutTailerTests`, `CodexScanTests` |
| rename live e worker filtering | `CodexSessionIndexStoreTests`, `CodexAdmissionRulesTests` |
| autorità ibrida e stale-write rejection | `CodexIngressCoordinatorTests` |
| app-server persistente | `CodexAppServerProtocolTests` + prova runtime 0.144.6 |
| custom homes e hook trust conservativo | `CodexHomeTests` |
| Claude parity corretta | `HookConfiguratorTests`, `SessionEventReducerTests`, test JSONC/native approvals/jump |

## Verifica live finale

- [x] Backup restorable creato in `~/.vedetta/backups/terminal-parity-20260721-123029/`: settings Claude, hooks/config Codex e session index. Hash SHA-256 registrati prima delle mutazioni.
- [x] L’installazione ha inoltre creato il backup atomico `~/.vedetta/backups/hooks-default.json.2026-07-21T10-32-45Z`.
- [x] Manifest Codex confrontato: sei eventi VI esatti, matcher vuoto solo PostToolUse, timeout 7200/5. Claude mantiene i 12 eventi VI.
- [x] `~/.codex/config.toml` è byte-identico al backup (`5856b9…d6f855`): `notify`, feature e trust non toccati. Claude settings è rimasto byte-identico (`ac40fe…1229`).
- [x] Fallback senza app: fixture PermissionRequest mentre il socket era assente → exit 0, stdout 0 byte, nessun allow/deny sintetico.
- [x] Rename reale via app-server `thread/name/set`: `codex-vedetta` → `codex-vedetta-live-check` osservato nel socket dump senza restart → ripristinato a `codex-vedetta`.
- [x] Worker hook late-classification: card provvisoria count 1 → titolo `Codex Companion Task:` → count 0; il test unitario conferma rimozione atomica del terminal mapping.
- [x] Codex CLI reale in terminale VS Code: thread `019f8443-50f1-7050-a21e-aef381bcc7c0`, un `pwd` in sandbox read-only, risposta `CODEX_FINAL_LIVE_OK`, stato finale `waitingForInput`, tool pulito.
- [x] Terminal binding Codex persistito: VS Code bundle, window ID 13718 e pidChain di 10 processi; URI companion verificato con `owns=true` e nuova riga in `ext.log`.
- [x] Claude Code reale non persistente: sessione `56661e4f-b7bb-4b75-aa81-ec4db7bebd02`, risposta `CLAUDE_FINAL_LIVE_OK`, stato finale `completed`.
- [x] Socket dump congiunto: 0 ID duplicati, 0 fixture/`.`/`Codex Companion Task:` visibili, 0 approval pendenti.
- [x] App-server persistente: un processo Codex figlio di Vedetta (PID 67081/67083) serve usage e hook trust; il Codex Desktop estraneo non è considerato.

### Nota sulla verifica approval

Il primo tentativo di isolare una fixture cambiando `HOME` non era valido: Foundation ha continuato a risolvere la home dell’account e due richieste `pwd` sono arrivate alla vecchia app. Matteo le ha autorizzate manualmente; la card sintetica `.` è scomparsa al riavvio ed è assente nel dump finale. La prova valida è stata ripetuta soltanto mentre Vedetta era realmente spenta, con stdout vuoto e senza interazione utente.

### Race emersa dal live test

Le prime sessioni Claude lanciate subito dopo il bootstrap hanno mostrato `running` dopo l’uscita. Il trace `--include-hook-events` ha provato che Claude aveva emesso Stop; la causa era `EventServer.handleConnection` detached, che non garantisce ordine fra connessioni. Il bridge ora assegna il tempo di invocazione e i writer Claude/Codex rifiutano eventi hook più vecchi dell’ultimo applicato. Dopo rebuild/relaunch, Claude termina `completed` e Codex `waitingForInput`.
