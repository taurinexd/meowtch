# Multi-account Claude — usage realtime nel notch

Data: 2026-07-24 · Basata sulla ricerca di fattibilità (workflow a 13 agenti, verifiche
adversariali su fonti primarie + verifiche empiriche locali su Claude Code 2.1.218) e sulle
decisioni UI prese in chat. Priorità: Claude; Codex resta com'è (già multi-home).

## Obiettivo

Vedere in tempo reale l'usage (finestra 5h + weekly) di **3+ account Claude** in una sola
schermata: click sulla strip usage → il notch espanso mostra provider → account con le barre
di quota, al posto delle card sessione. Gestione account in Settings → pagina nuova
**Accounts**. Nice-to-have: click su un account → comando di login pronto nel terminale.

## Fondamenta verificate (ricerca 2026-07-24)

- **Nessuna feature ufficiale multi-profilo.** La primitiva è `CLAUDE_CONFIG_DIR`: una
  directory per account, isola settings.json (→ hook e statusline **per-account**),
  transcript (`<dir>/projects/`) e credenziali.
- **Credenziali su macOS**: Keychain, service `Claude Code-credentials` per `~/.claude`,
  `Claude Code-credentials-<sha256(NFC(path)).hex[:8]>` per config dir custom (verificato
  decompilando il binario 2.1.218; comportamento NON documentato → mai darlo per scontato:
  calcolare il nome e verificarne l'esistenza, con fallback su item legacy condiviso e su
  `<dir>/.credentials.json`).
- **Quota server-authoritative senza sessione attiva**: `GET
  https://api.anthropic.com/api/oauth/usage` con `Authorization: Bearer <accessToken>`,
  `anthropic-beta: oauth-2025-04-20`, `User-Agent: claude-code/<versione CLI reale>`.
  Risponde con `five_hour` / `seven_day` (+ bucket per-modello) `{utilization, resets_at}` —
  gli stessi dati di `/usage`. **Verificato live da questa macchina (200 OK).** Non consuma
  quota. Endpoint non documentato: pattern comprovato da claude-swap, claude-quota,
  ClaudeBar, better-ccflare, SessionWatcher.
- **Push gratuito**: dalla 2.1.80+ lo stdin della statusline include `rate_limits` — il
  nostro harvester attuale, replicabile per-account.
- **Caveat verificati**: il polling non ha garanzie (429 con Retry-After anche lunghi se
  l'account ha molte sessioni attive che pollano) → backoff esponenziale + dato stale con
  età, mai % spacciata per fresca. **Mai fare refresh dei token** (race documentate col
  Keychain di Claude Code): token scaduto → riga stale finché una sessione di quell'account
  non gira.
- **Identità account**: `CLAUDE_CONFIG_DIR=<dir> claude auth status --json` → email, org,
  subscriptionType (locale, ~1-2 s). Verificato.

## Architettura

### Modello (VedettaKit)

```
ClaudeAccount { id: String,          // path canonico della config dir (chiave stabile)
                configDir: URL,
                alias: String?,      // etichetta utente; default → email da auth status
                email: String?, subscriptionType: String? }   // cache identità
```

- `ClaudeAccountRegistry`: mirror di `CodexHomeRegistry` (pattern in-repo). L'account
  default `~/.claude` esiste sempre e non è rimovibile; gli altri in UserDefaults
  (`claude.customAccounts`), notification `.vedettaClaudeAccountsChanged`.
- `KeychainCredentialLocator` (pure): dato un configDir produce i **candidati** di lettura
  in ordine: service namespaced (hash calcolato), service legacy `Claude Code-credentials`
  (solo per la dir default), file `<dir>/.credentials.json`. Unit-testabile senza Keychain.

### Fonti dati per account (ibrido push + pull)

1. **Push — statusline per-account (default, zero rete).** Lo script harvester viene
   parametrizzato: scrive `~/.vedetta/cache/rl-<hash8(dir)>.json` (la dir default continua
   su `rl.json` per compatibilità). Installato nell'`settings.json` di ogni account con lo
   stesso state machine owner/claim di oggi (per-account). Fresco solo con sessioni attive.
2. **Pull — OAuth usage probe (opt-in esplicito, OFF di default).** `OAuthUsageProbe`
   (app target): legge l'accessToken via i candidati del locator (`security
   find-generic-password` / file), chiama l'endpoint, aggiorna le finestre. Cadenza base
   **300 s per account, staggered**; su 429 backoff esponenziale (600 s → 30 min) con
   rispetto di Retry-After; su token scaduto/assente nessun tentativo di refresh, solo
   marcatura stale. User-Agent con la versione CLI reale (`claude --version` cachata).
   L'opt-in è la **prima e unica breccia nel principio zero-rete**: toggle dedicato con
   testo chiaro ("chiama l'API di Anthropic con le credenziali già presenti sul Mac,
   sola lettura, endpoint non documentato").
3. **Hook per-account (prerequisito sessioni visibili).** `installClaudeHooks(at:)`
   parametrizzato sulla config dir (overload come i gemelli Codex): le sessioni lanciate
   con `CLAUDE_CONFIG_DIR=<dir>` diventano visibili nel notch. Il bridge cattura
   `CLAUDE_CONFIG_DIR` dall'ambiente dell'hook e la mette nell'envelope → ogni sessione è
   taggata col suo account (serve per il pallino ● "attivo" nel drill-down).

### UsageModel

- Le finestre Claude diventano per-account: `claudeAccounts: [AccountUsage]` con
  `{ accountId, fiveHour, sevenDay, updatedAt, source: push|pull }`; la strip continua a
  mostrare **un** valore (l'account attivo: quello con sessioni live più recenti, altrimenti
  il default). `cachePaths` (già `[String]`, seam disegnato) diventa la lista dei
  `rl-<hash>.json`; il merge non è più "il più fresco vince" ma per-account
  (push vs pull: vince il più recente dei due).
- Freshness: una finestra è **stale** oltre 10 min dall'`updatedAt`; la UI mostra l'età
  ("stale 2h"), mai la % da sola.
- Il comando socket `{"cmd":"usage"}` cresce con le chiavi per-account (dump-diff loop).

### UI

1. **Strip (top bar)**: invariata nel layout; il tap apre/chiude il **drill-down** (il
   cycle provider si sposta dentro la vista). Flash di feedback esistente riusato.
2. **Drill-down**: nuovo ramo in `NotchView.expandedContent`, stato in `NotchUIModel`
   (`usageDrilldown: Bool`, reset al collasso come showAllSessions; l'interrupt takeover
   vince sempre). Contenuto: sezione CLAUDE con una riga per account — `●` se attivo
   (sessioni live taggate), alias/email, barra 5h + %, barra weekly + %, oppure
   "— stale <età> —"; sezione CODEX con le finestre esistenti. Colori alle soglie 50/80%
   come la strip. Esc/tap sulla strip/collasso → torna alle card.
3. **Riga account cliccabile (nice-to-have)**: click → copia negli appunti
   `CLAUDE_CONFIG_DIR=<dir> claude` + feedback "copied" sulla riga. Niente focus rubato,
   funziona con ogni terminale. (Apertura diretta di un terminale: fuori scope v1.)
4. **Settings → pagina nuova "Accounts"** (case nuovo dell'enum Page, icona
   `person.2.badge.key.fill`):
   - riga per account: alias editabile, sottotitolo email · piano (da `auth status`,
     bottone refresh), stato hook (Install/installed) e statusline owner con claim
     per-account (riuso dello state machine esistente), Remove (solo registry, la dir
     resta; offerta di rimozione hook con backup);
   - "Add account…": NSOpenPanel su una directory (creata se serve, suggerimento
     `~/.claude-<nome>`); se la dir non è loggata, hint con il comando di login da
     copiare (il login OAuth è interattivo nel browser: non possiamo farlo noi);
   - sezione "Network refresh": il toggle opt-in del pull + intervallo (300/600 s) +
     disclaimer.
   - La pagina Usage esistente resta per il display (strip on/off, provider preferito).

### Fix incidentale incluso

`VedettaSetup.removalKey(for:)` ha l'interpolazione rotta (stringa letterale
`"(codexRemovalKey).(codexHome.path)"`): tutte le Codex home custom condividono una removal
key. Fix + test di regressione.

## Fuori scope v1

Refresh token OAuth nostro; apertura automatica del terminale per il login; bucket
per-modello (Opus/Sonnet) nel drill-down; multi-account Codex (già coperto dal multi-home);
proiezioni "tempo al limite".

## Test e verifica

- **Unit** (VedettaKit): registry (persistenza, canonicalizzazione, default non rimovibile);
  locator Keychain (nome service per dir default vs custom, ordine candidati); parsing
  risposta oauth/usage (fixture JSON); merge push/pull per-account e staleness; backoff
  (sequenza 429 → intervalli, reset dopo successo); tagging account nell'envelope del bridge.
- **E2E** (con conferma manuale di Matteo): secondo account reale in `~/.claude-test` →
  login, hook installati, sessione live visibile e taggata; drill-down con 2+ account e
  barre reali; opt-in rete off→on → righe pull che si popolano senza sessioni attive;
  429 simulato (o raggiunto) → backoff e riga stale; click riga → comando negli appunti.
- Il principio zero-rete resta il default: con l'opt-in OFF, nessuna connessione (verifica
  con `nettop`/proxy durante il giro E2E).
