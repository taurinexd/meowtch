# CALL mode — copilota per chiamate cliente

## Contesto

Meowtch oggi è un tool per chi programma con agent AI: la notch mostra sessioni
Claude Code e Codex, approvazioni, domande, usage. Matteo però fa anche call con
clienti su Google Meet, dove serve tutt'altro: un assistente che ascolta la
conversazione e suggerisce risposte, **invisibile quando condivide lo schermo**.

Esiste un intero genere di tool che fa questo (Cluely e i suoi cloni open source:
Glass, Pluely, Natively, cue, OpenCluely, Vysper, hiddenai). Sei su sette sono Electron o
Tauri e cross-platform, e usano STT portabile — whisper.cpp in locale o servizi cloud.
L'eccezione, hiddenai, è Swift nativo ma è un giocattolo da 26 stelle senza cattura dell'audio
di sistema. Meowtch è Swift nativo su macOS 26: le ragioni che portano quei progetti alle loro
scelte tecniche **non valgono qui**, e questo apre soluzioni che loro non possono usare.

La feature si aggiunge come **modalità**, non come app separata: un toggle
CODE/CALL nella notch espansa, a sinistra del pulsante audio.

## Scope

**Dentro:**
- Toggle CODE ⇄ CALL nella `topBar` della notch espansa
- Protezione dalla cattura schermo (`sharingType = .none`) su tutte le superfici, solo in CALL
- Cattura audio dual-channel: audio di sistema (il cliente) + microfono (Matteo), separati
- Trascrizione live on-device in italiano (`SpeechAnalyzer` / `SpeechTranscriber`)
- Endpointing semantico + gate che decide quando c'è un'occasione di risposta
- Hotkey di override manuale ("rispondi ora")
- Motore di risposta pluggable: `claude` CLI (default) e Ollama (fallback/privacy)
- Contesto: file Webgas globale + scheda cliente dentro la cartella del cliente
- Fine call: proposta di aggiornamento della scheda cliente
- Consumi in tempo reale agganciati a `UsageModel`, con auto-switch a Ollama sotto soglia
- Contatore live durante la risposta (secondi + token), nella forma dello spinner di Claude Code

**Fuori:**
- Trascrizione/notetaking come deliverable → lo fa già Gemini di Meet, nativamente.
  ⚠️ Precondizione da verificare: *"Take notes for me"* richiede Workspace **Business
  Standard o superiore** (non Starter). Se il piano Webgas fosse Starter, questa voce
  andrebbe riconsiderata
- Screenshot → LLM (esiste in 7 tool su 7, ma nasce per barare a LeetCode; nelle call
  commerciali il cliente parla, non mostra algoritmi)
- Process disguise / evasione del proctoring
- RAG vettoriale locale (scartato a favore di file + scheda cliente: 80% del valore, 5% della complessità)
- Salvataggio del trascritto su disco
- Windows/Linux (irrilevante: l'app è macOS-only)

## Evidenze empiriche raccolte (2026-09-02, macchina di Matteo, macOS 26.5.2)

Tutto ciò che segue è stato verificato, non assunto.

### 1. L'invisibilità funziona ancora, contro quanto dice Apple

Le fonti si contraddicevano: il [forum Apple](https://developer.apple.com/forums/thread/792152)
sostiene che da macOS 15.4 `sharingType = .none` blocchi solo le API CoreGraphics
legacy e **non** ScreenCaptureKit; test indipendenti di marzo 2026 sostenevano il
contrario. Risolto con uno spike: due `NSPanel` a colori pieni, uno protetto e uno
di controllo, catturati con tre motori.

| Motore di cattura | Pannello di controllo | Pannello protetto |
|---|---|---|
| `SCScreenshotManager` (ScreenCaptureKit) | visibile | **assente** |
| `/usr/sbin/screencapture` (Apple) | visibile | **assente** |
| Chrome `getDisplayMedia` (campione WebRTC) | visibile | **assente** |
| **Google Meet, condivisione reale** | visibile | **assente** |

Verdetto: **`sharingType = .none` è rispettato su macOS 26.5.2**, Google Meet incluso —
verificato prima sulla pagina campione WebRTC `getDisplayMedia` e poi, da Matteo, dentro una
condivisione schermo reale in una riunione Meet. Non resta ipotesi: è lo scenario d'uso vero.

Tre limiti da conoscere:
- È un flag **per-finestra**: va messo su ogni superficie (pannello notch, popover,
  Settings). Una dimenticata e quella si vede.
- Le finestre protette **restano elencate** in `SCShareableContent` (verificato: il
  probe le vede entrambe). Sparisce il contenuto, non la voce nel selettore "condividi
  una finestra" di Chrome.
- Da macOS 15.4 esiste un'entitlement che consente a client di cattura privilegiati
  di vedere comunque le finestre protette. Non si applica a Chrome/Meet, ma potrebbe
  applicarsi a tool di remote support o proctoring aziendale. È "invisibile a Meet",
  non "invisibile in assoluto".

Nota collaterale: `CGWindowListCreateImage` è stato **rimosso dall'SDK** in macOS 15
(`obsoleted`), quindi la via legacy non è più nemmeno compilabile.

**Stato attuale di Meowtch: nessun `sharingType` in tutto `App/Sources`.** Oggi, in
ogni condivisione schermo, il cliente vede le card delle sessioni, i nomi dei progetti
e le domande in attesa. Va chiuso a prescindere da CALL.

### 2. La trascrizione italiana on-device esiste e non costa nulla

`SpeechTranscriber` (macOS 26) supporta 30 locale, fra cui **`it-IT` e `it-CH`**
(verificato con probe). On-device, senza percorso server, senza modelli da impacchettare.

Caveat: `installedLocales` è **vuoto** — l'asset italiano si scarica al primo uso
tramite il sistema. Serve gestire quel primo avvio nell'UI.

### 3. La CLI `claude` regge una sessione persistente

Versione installata: 2.1.258. Flag rilevanti verificati in `--help`:
- `--input-format stream-json` — input realtime su stdin: **un processo per call**, non per risposta
- `--output-format stream-json` — risposte in streaming
- `--append-system-prompt` — inietta la persona della call senza toccare la config di Matteo
- `--tools ""` — **disabilita tutti i tool**: copilota bloccato su pura generazione di testo,
  nessuna sorpresa e nessuna latenza da tool call. (⚠️ `--restricted` da solo **non** basta:
  verificato in `--help`, rimuove solo i tool che eseguono comandi o codice — Bash, REPL — e
  WebFetch; Read ed Edit resterebbero attivi. Si usa comunque, insieme a
  `--strict-mcp-config`, per ignorare settings utente/progetto e server MCP.)
- `--model` — scelta del modello

### 4. Lo stream porta con sé i consumi, in push

L'evento `result` contiene `usage`, `modelUsage` per modello, `total_cost_usd`,
`duration_ms`. E lo stream emette un evento di tipo **`rate_limit_event`**.

Le due finestre che porta sono **le stesse che `UsageModel` già disegna nella notch**.

**Schema confermato** catturando un evento reale (`--tools "" --output-format stream-json`):

```json
{"type":"rate_limit_event","rate_limit_info":{
  "status":"allowed","rateLimitType":"five_hour","resetsAt":1788369600,
  "overageStatus":"rejected","isUsingOverage":false,
  "unifiedWindows":{
    "five_hour":{"utilization":0.06,"resetsAt":1788369600},
    "seven_day":{"utilization":0.05,"resetsAt":1788732000}}},
 "uuid":"…","session_id":"…"}
```

`utilization` è una **frazione** (0.06 = 6% consumato), `resetsAt` è un Unix timestamp,
entrambe le finestre sono presenti in ogni evento. `overageStatus` / `isUsingOverage`
dicono anche se si sta sconfinando nel piano a consumo.

### 5. L'overhead per sessione della CLI è alto — la sessione persistente è obbligatoria

Misura reale: prompt *"rispondi solo: ok"*, quattro token di output.

```
total_cost_usd = 0.158565
cache_creation_input_tokens = 15345
cache_read_input_tokens = 10010
```

Non è il modello, è il contesto che la CLI carica all'avvio di ogni sessione. Venti
risposte in una call, ognuna con sessione nuova, costerebbero ~$3 e aprirebbero un
buco reale nella finestra 5h usata per lavorare. **Un processo per call, riusato per
ogni risposta.**

### 6. Hardware

M1 Pro, 16 GB. Ollama **non installato**. Rilevante per il dimensionamento del
motore locale: un 8B quantizzato occupa 5-6 GB residenti mentre girano Meet in video,
la trascrizione on-device e le sessioni di lavoro.

## Cosa si impara dai tool esistenti

Licenze e stelle verificate via API GitHub il 2026-09-02; il resto viene dai README.

| Tool | Stack | Licenza | ⭐ | Audio sistema | STT |
|---|---|---|---|---|---|
| Glass (Pickle) | Electron + Rust | GPL-3.0 | 7596 | sì, con AEC | Whisper locale o cloud |
| Pluely | Tauri + Rust | GPL-3.0 nel repo, README dice proprietaria | 2619 | sì | non specificata |
| Natively | Electron + Rust + SQLite | NOASSERTION (custom, non commerciale) | 2412 | sì | 4 locali + 8 cloud |
| cue | Electron | GPL-3.0 | 1292 | sì, SCK loopback | whisper.cpp |
| OpenCluely | Electron | Apache-2.0 (README dice MIT) | 878 | **no, solo mic** | Whisper o Azure |
| Vysper | Electron | Apache-2.0 | 135 | sì, via Sox | **Azure STT** |
| hiddenai | **Swift + SwiftUI** | MIT | 26 | **no, solo mic** | Whisper API (cloud) |

I due che catturano solo il microfono sentono l'utente, non l'interlocutore: inutili in call.
È la conferma che il dual-channel non è un lusso.

**Perché quasi tutti usano Whisper, e perché noi no:** sono cross-platform e il framework
Speech di Apple è macOS-only; sono nati prima di macOS 26 (`SpeechAnalyzer` è di settembre
2025, e prima c'era solo `SFSpeechRecognizer`, pensato per dettatura breve); devono supportare
macOS 12+; da Node non si raggiunge il framework Apple senza scrivere un modulo nativo.
Nessuna di queste vale per Meowtch. Chi non usa Whisper usa comunque un servizio cloud
(Azure per Vysper), che per una call con un cliente è la scelta peggiore delle due.

**La lezione più importante viene dallo spec Auto Answer v2 di Natively** (repo
clonato come riferimento architetturale; vedi nota di licenza in fondo):

- La latenza percepita **non è il modello**. Misurano tre numeri:
  `median_endpoint_to_decision_ms`, `p95_endpoint_to_decision_ms`,
  `median_decision_to_first_token_ms`. Il tempo totale di generazione non è nemmeno
  strumentato, perché con lo streaming non conta.
- **Endpointing semantico, non timer fisso**: testualmente, «*The goal is not merely to
  detect `?` or wait 900 ms after an STT final*» e «*Do not hardcode a universal 900 ms
  trigger anymore*». Il timer riparte a ogni nuovo parlato e chiude solo con silenzio
  sufficiente **e** frase che sembra completa.
- **La qualità è non rispondere nel momento sbagliato**: le metriche dichiarate
  prioritarie sono `false_trigger_rate` e `premature_trigger_rate`, non la bontà della
  risposta.
- **Il detector non chiama mai l'LLM di risposta** (testuale: «*The detector should NOT
  directly call the answer LLM*»).
- **Due risposte non vanno mai in streaming in parallelo**: la seconda si accoda.
- **Il tiering dei modelli è il design**, non un ripiego: ogni provider espone un id
  "Fastest" e uno "Highest Quality".
- **Un registry multi-provider è manutenzione perpetua**: i commenti nel loro codice
  documentano id Llama ritirati da Groq (luglio e agosto 2026) e id NVIDIA che
  rispondono `410 Gone` pur essendo elencati nel catalogo. Ragione in più per fermarsi
  a due motori.

## Architettura

```
CALL mode
├── CallModeController      stato CODE/CALL; applica sharingType a tutte le superfici
├── AudioCapture            2 canali separati: sistema (cliente) + mic (Matteo)
├── LiveTranscriber         SpeechAnalyzer per canale → segmenti volatili e finali
├── TurnEndpointer          quando il cliente ha davvero finito di parlare
├── AnswerTrigger           è un'occasione di risposta? (non chiama mai il motore)
├── AnswerEngine  «protocollo»
│   ├── ClaudeCLIEngine     un processo per call, stream-json su stdin/stdout
│   └── OllamaEngine        HTTP streaming su localhost:11434
├── ContextStore            contesto Webgas globale + scheda cliente
├── CallUsageTracker        terza sorgente per UsageModel + budget e auto-switch
└── CallView                UI nella notch espansa
```

Collocazione secondo le convenzioni del repo: modello e parser puri in `VedettaKit`
(`TurnEndpointer`, `AnswerTrigger`, `ContextStore`, parsing degli eventi stream-json),
tutto ciò che tocca AppKit, audio o processi in `Vedetta`.

### Confini non negoziabili

1. **Il trigger non chiama mai il motore di risposta.** Decisione e generazione sono
   percorsi separati: la decisione costa zero e non eredita la latenza del modello.
   (Se le euristiche non bastassero, il trigger può interpellare un modello locale
   piccolo — che resta comunque un percorso distinto dal motore di risposta.)
2. **Due risposte non vanno mai in streaming insieme.** Seconda domanda durante uno
   streaming → si accoda.
3. **Si misurano `endpoint → decision` e `decision → first token`** fin dal primo
   commit. Senza strumentazione si ottimizza a caso.

## Il trigger

**Vantaggio strutturale rispetto ai tool Electron:** catturando due canali separati,
il canale *è* l'etichetta di chi parla. Sistema = cliente, mic = Matteo. Niente
diarizzazione, niente speaker label da indovinare, niente modelli VAD.

⚠️ **Il vantaggio vale solo in cuffia.** A speaker aperti la voce del cliente esce dagli
altoparlanti e rientra nel microfono: il canale mic conterrebbe entrambe le voci e il gate
crederebbe che sta parlando Matteo ogni volta che parla il cliente — sopprimendo proprio i
suggerimenti che servono (vedi "tre soppressioni"). Glass risolve con un AEC scritto in Rust;
noi **non** implementiamo cancellazione d'eco. Quindi:

- **L'uso in cuffia è una precondizione dichiarata**, non un consiglio.
- All'ingresso in CALL si legge il device di output corrente: se non è né cuffie né headset,
  la notch avvisa che il rilevamento sarà inaffidabile. Meglio un avviso esplicito che un
  copilota che tace senza spiegazioni.
- Se in futuro servisse l'uso a speaker aperti, l'AEC è un progetto a sé, non un ritocco.

**Endpointer:** il timer parte quando il cliente smette di parlare, riparte a ogni
nuovo parlato, chiude quando il silenzio supera la soglia **e** i controlli di
completezza non indicano una frase troncata. Soglie come costanti nominate, non magic
number sparsi.

**Rischio principale, specifico all'italiano.** In inglese la sintassi interrogativa
aiuta (`do you`, `can we`, inversione). In italiano una domanda chiusa è
morfologicamente identica all'affermazione: *"Riuscite a farlo entro giugno"* e
*"Riuscite a farlo entro giugno?"* hanno le stesse parole nello stesso ordine.
Restano la punteggiatura emessa da `SpeechTranscriber` e i marcatori lessicali (chi, cosa,
come, quando, quanto, perché, quale, potete, riuscite, avete). **È il punto in cui il gate
sbaglierà di più**, ed è il candidato numero uno per un modello locale piccolo se le euristiche
non bastano.

⚠️ Assunzione non ancora verificata: che `SpeechTranscriber` emetta davvero punteggiatura
interrogativa in italiano, e che lo faccia in modo affidabile. Serve una prova con audio reale
prima di costruirci sopra il gate — se la punteggiatura non arriva, restano solo i marcatori
lessicali e il modello piccolo diventa necessario, non opzionale.

**Tre soppressioni**, che valgono più di qualsiasi raffinatezza sul rilevamento:
- se sta parlando Matteo (canale mic attivo) → nessun suggerimento: sta già rispondendo
- se una risposta è in streaming → la successiva si accoda
- se la domanda è quasi identica a una già risposta → si ignora

**Rete di sicurezza: hotkey di override.** Premuta, il copilota risponde sull'ultimo
tratto di conversazione senza consultare nessuna euristica. Rende non fatali gli errori
del gate: se sbaglia in difetto la hotkey copre, se sbaglia in eccesso le metriche lo
dicono e si alza la soglia.

## Superficie

**Il toggle** sta nella `topBar` di `NotchView` (oggi:
`usageSummary → Spacer → speaker → gear`), inserito a sinistra del pulsante audio. È il
solo punto di ingresso: nessuna finestra nuova, nessuna voce di menu.

**In CALL, notch espansa:** il filo della conversazione con i due interlocutori visivamente
distinti (il canale è già l'etichetta, non serve indovinare chi parla), il suggerimento corrente
che scorre in streaming, e lo stato del motore con il consumo progressivo della call.

**Contatore live mentre il copilota risponde**, nella forma dello spinner di Claude Code
(`43s · ↓ 2.7k tokens`): secondi trascorsi dall'inizio della risposta e token accumulati.
Fattibile perché la CLI espone **`--include-partial-messages`** (verificato in `--help`), che
emette i chunk mentre arrivano invece del solo `result` finale — quindi i token si contano in
tempo reale, non a posteriori. Gli stessi due numeri servono anche a strumentare
`decision_to_first_token_ms` senza codice aggiuntivo.

**In CALL, notch collassata:** un indicatore minimo — in ascolto / suggerimento pronto —
coerente con la glance mode già esistente.

**Modalità e invisibilità sono due cose distinte** (deciso in implementazione, 2026-09-02).
CALL dice *cosa fa* la notch; un secondo interruttore — un fantasmino in pixel art accanto
al toggle — dice *se è catturabile*. CALL accende l'invisibilità e CODE la spegne, ma il
fantasmino ha l'ultima parola su entrambi.

Non è un vezzo: legati alla stessa variabile, la superficie CALL sarebbe **impossibile da
sviluppare**, perché nel momento in cui la notch ha qualcosa da mostrare nessuno screenshot
può mostrarlo. La separazione compra anche un caso utile di suo: nascondere la notch mentre
si programma, durante una demo condivisa.

Il fantasmino è pixel art e non un SF Symbol perché in SF Symbols **il fantasma non esiste**
(verificato) e perché l'app è già 8-bit; si compone con una piccola `xmark` esattamente come
il pulsante del volume.

**Applicazione:** all'accensione ogni superficie passa a `sharingType = .none` e allo
spegnimento torna a `.readOnly`. Vale per il pannello notch, i popover e la finestra
Settings: **una sola dimenticata vanifica la feature**. Serve un punto unico che enumera le
finestre, non chiamate sparse.

⚠️ Effetto collaterale confermato: mentre è invisibile, uno screenshot **mirato alla
finestra** (`Cmd+Shift+4` → Spazio) fallisce con un errore di sistema invece di produrre
un'immagine vuota. La cattura a schermo intero riesce e si limita a omettere la finestra.
È il primo dei «number of system services» che l'header di `NSWindow` nomina senza elencare,
e va spiegato nella copy di Settings: un errore secco senza contesto fa pensare a un'app rotta.

## Contesto e schede cliente

```
ContextStore
├── contesto Webgas globale     ~/.vedetta/call/webgas.md
└── scheda cliente              <cartella scelta>/.meowtch/client.md
```

Prima della call si seleziona la cartella del cliente (es. `~/Code/design/studio`) e la
scheda vive lì, accanto al lavoro. A fine call il copilota **propone** una modifica —
cosa ha chiesto il cliente, cosa gli è stato promesso, obiezioni emerse — e Matteo
approva o scarta. La scheda cresce a ogni chiamata e la successiva parte informata.

**Il trascritto muore in RAM.** Niente audio, niente trascritto, niente suggerimenti su
disco. Il riassunto della riunione resta a Gemini di Meet, che gestisce anche il consenso dei
partecipanti (Google ha annunciato il consenso esplicito obbligatorio ad aprile 2026).

**Rischio git, e come si chiude.** La scheda contiene budget, obiezioni e promesse:
roba che non deve finire in un commit. Metà delle cartelle cliente di Matteo sono repo
git — verificato: `shop-wp`, `erp-connector`, `theme` e `internal-site` lo sono,
`design/studio` e `client-b` no.
Quindi: file sotto `.meowtch/`, e alla creazione Meowtch lo aggiunge a
**`.git/info/exclude`**, non a `.gitignore` — `.gitignore` è tracciato e comparirebbe
come modifica nel repo del cliente, `.git/info/exclude` è locale e invisibile.

Due casi da gestire esplicitamente, entrambi presenti fra le cartelle di Matteo:
- **cartella non versionata** (`design/studio`, `client-b`): nessun `.git`, l'esclusione è un
  no-op silenzioso, non un errore;
- **worktree git**: `.git` è un *file*, non una directory, e `info/exclude` vive nel git dir
  principale. Va risolto con `git rev-parse --git-common-dir`, non concatenando `/.git/info/`.

**Nessuna eredità di `AGENTS.md` / `CLAUDE.md`, ottenuta non lanciando il processo lì.**
La cartella cliente è *dove vive la scheda*, non la working directory del copilota: il processo
parte con cwd in `~/.vedetta/call/`, una directory neutra e priva di file di memoria, e riceve
`webgas.md` + `client.md` come testo via `--append-system-prompt`.

Il motivo di questa scelta è una correzione emersa in revisione: **nessun flag della CLI
garantisce di ignorare `CLAUDE.md`/`AGENTS.md`**. `--restricted` ignora i *settings* utente,
progetto e locali — verificato nel testo completo di `--help` — ma non menziona i file di
memoria. Costruire su quel comportamento significherebbe dipendere da qualcosa di non
documentato; cambiare working directory elimina il problema alla radice invece di aggirarlo.
Un `AGENTS.md` che parla di Pint e di migration non c'entra nulla con una call commerciale.

## Motori di risposta

Protocollo unico, due implementazioni.

**`ClaudeCLIEngine` (default).** Un processo `claude -p --input-format stream-json
--output-format stream-json --include-partial-messages --append-system-prompt <persona>
--tools "" --restricted --strict-mcp-config` per call. (`--include-partial-messages` serve al
contatore live e alla misura di `decision_to_first_token_ms`: senza, i token si conoscono solo
a risposta finita.)
Ogni domanda è un messaggio JSON su stdin; la risposta torna in streaming e finisce
nella notch. La sessione mantiene da sola il filo dell'intera conversazione.

**`OllamaEngine`.** HTTP streaming su `localhost:11434`. Tre casi d'uso reali che il
cloud non copre: cliente sensibile in cui nulla deve lasciare la macchina, call offline,
zero consumo del rate limit.

**Perché la CLI per prima, nonostante l'attrattiva di "solo locale".** Ollama-only è
*più* lavoro, non meno: la CLI è già installata, è un sottoprocesso, zero dipendenze
nuove, zero budget di RAM, qualità massima. Ollama significa installazione, ~5 GB di
modello e prompt tuning per un modello piccolo, su 16 GB già occupati da Meet in video.
E soprattutto: la prima domanda a cui rispondere è *"un copilota in call serve
davvero?"*. Se non è utile con un modello frontier dietro, non lo sarà con un 8B —
validare col motore più debole rischia di uccidere una buona feature su una cattiva
prima impressione.

**Ollama non è l'alternativa al default: è la sua rete di sicurezza** (vedi budget,
sotto). È la ragione più solida per costruire il protocollo a due motori fin da subito.

## Consumi in tempo reale

Non serve una sonda nuova: **il motore stesso è il feed**.

```
UsageModel  ←  push    (statusline)        esiste — muta in headless
            ←  pull    (sonda OAuth)       esiste — a intervalli
            ←  stream  (rate_limit_event)  NUOVO — push a ogni risposta
```

La terza sorgente è più fresca della pull (nessun intervallo di polling) e copre esattamente
il caso in cui la push è cieca. **Verificato empiricamente**: lanciando `claude -p` con
`--settings '{"statusLine":{"type":"command","command":"touch <marker>"}}'`, il marker non viene
mai creato — in print mode la statusline non viene eseguita, quindi `rl.json` non si aggiorna e
la sorgente push resta ferma per tutta la durata della call. Si innesta nel merge per-account che
`UsageModel` già fa, non accanto.

L'evento `result` di ogni risposta porta inoltre `usage`, `modelUsage` e
`total_cost_usd`: totale progressivo della call, mostrabile in notch mentre si parla.

**Il monitoraggio è un comando, non un cruscotto.** La soglia si esprime sul campo reale:
`unifiedWindows.five_hour.utilization`, che misura la quota **consumata**, non quella residua
(`0.06` = 6% usato). Default proposto: **`utilization ≥ 0.80`**, cioè meno del 20% di finestra
5h rimasto, configurabile in Settings. Il verso va scritto così nel codice e nel test: espresso
come "percentuale residua" si implementa invertito senza che nulla se ne accorga.
Quando la soglia viene superata la notch avvisa e il copilota
**passa da solo a `OllamaEngine`** per il resto della chiamata. Assistenza degradata
invece di assistenza assente davanti a un cliente. Se `OllamaEngine` non è
disponibile — Ollama non installato, nessun modello — l'avviso resta e il copilota si
sospende: mai un fallimento silenzioso a metà call.

## Privacy, permessi, contratto

**Permessi nuovi:** microfono (`NSMicrophoneUsageDescription`) e audio di sistema
(`NSAudioCaptureUsageDescription`). ⚠️ Da verificare se `SpeechAnalyzer`, essendo
esclusivamente on-device, richieda anche l'autorizzazione al riconoscimento vocale come
faceva `SFSpeechRecognizer`: non è stato accertato, e il probe sui locale non ne ha avuto
bisogno — ma leggere i locale non è trascrivere.

Per l'audio di sistema si sceglie il **process tap Core Audio**
(`AudioHardwareCreateProcessTap` + `CATapDescription`, macOS 14.2+) mirato sul processo del
meeting, invece di ScreenCaptureKit. Motivi verificati:

- È una **categoria TCC distinta** (`NSAudioCaptureUsageDescription`): il prompt dice
  *"System Audio Recording"*, non *"Screen & System Audio Recording"*. Richiesta più piccola
  e indicatore di privacy più onesto.
- Non cattura lo schermo, e non l'audio dell'intero sistema: si può puntare al solo processo
  della riunione.
- **Richiede un'identità di firma stabile**, perché il record TCC è indicizzato su quella.
  Meowtch ce l'ha già — *"Vedetta Dev Signing"* esiste esattamente per non perdere i grant
  Accessibility a ogni rebuild. Lo stesso meccanismo copre anche questo permesso.
- Dettaglio d'implementazione: è **`AudioDeviceStart` a far comparire il prompt**, non la
  creazione del tap. Il consenso va quindi richiesto all'ingresso in CALL, non all'avvio dell'app.

Esiste un'implementazione di riferimento leggibile, [insidegui/AudioCap](https://github.com/insidegui/AudioCap).
Resta comunque uno spike prima dell'implementazione, con SCK audio come fallback documentato.

**Emendamento alla regola no-telemetry.** `CLAUDE.md` dichiara: *"No telemetry, ever.
The only network traffic is the daily update check and the opt-in Claude usage probe."*
`ClaudeCLIEngine` manda il trascritto della call ad Anthropic. È una violazione
deliberata di una regola dichiarata e va scritta nel contratto, non fatta passare in
silenzio.

La distinzione che regge: *telemetria* è dato sull'utente, spedito per scopi del vendor,
senza che l'utente lo chieda; un copilota che risponde a una domanda posta dall'utente è
una chiamata di servizio richiesta. Traffico di rete sono entrambi, quindi la regola va
emendata comunque — ma l'emendamento è **"su iniziativa dell'utente, con consenso,
spento di default, con kill-switch"**, non "adesso facciamo analytics". Precedente
esistente nel repo: il kill-switch `remote_questions` di `RemoteBridge`.

`OllamaEngine` è l'unica configurazione che lascia la regola intatta.

## Metriche

Strumentate dal primo commit, esposte via socket per il debug:

```
endpoint_to_decision_ms      (mediana e p95)
decision_to_first_token_ms   (mediana)
false_trigger_rate           ← prioritaria
premature_trigger_rate       ← prioritaria
manual_override_rate         quante volte la hotkey ha coperto un buco del gate
```

## Rischi aperti

| Rischio | Mitigazione |
|---|---|
| Rilevamento domande in italiano (nessun marcatore sintattico) | Euristiche + punteggiatura prosodica; escalation a modello locale piccolo se la precisione è bassa; la hotkey rende gli errori non fatali |
| Process tap Core Audio (API C, poco battuta) | Ridimensionato: categoria TCC dedicata confermata, identità di firma già presente, implementazione di riferimento disponibile. Spike breve; fallback SCK audio |
| Download dell'asset `it-IT` al primo uso | UI di primo avvio dedicata, non un blocco silenzioso a metà call |
| `SpeechTranscriber` potrebbe non emettere punteggiatura interrogativa affidabile in italiano | **Misurato 2026-11-16 (audio sintetico)**: con `.fastResults` «?» su 9/10 domande con parola interrogativa, 0/10 sulle domande chiuse. Il gate usa testo volatile + silenzio, marcatori lessicali e un classificatore piccolo per le chiuse; hotkey come rete. Da ripetere su parlato umano |
| **Apple avverte che una finestra `NSWindowSharingNone` «will also not be able to participate in a number of system services»** (header di `NSWindow`), senza elencarli | Verifica esplicita in M1 su Mission Control e Stage Manager; la modalità è temporanea e non persiste fra i lanci, quindi l'esposizione è limitata alla durata della call |
| Rientro dell'audio del cliente nel microfono a speaker aperti | Cuffie come precondizione dichiarata + avviso sul device di output all'ingresso in CALL; nessun AEC |
| Entitlement di bypass su macOS 15.4+ | Documentato: "invisibile a Meet", non "invisibile in assoluto" |
| Costo/rate limit durante call lunghe | Sessione persistente + budget + auto-switch a Ollama |
| **Dipendenza da un'interfaccia non contrattuale**: `--tools ""`, lo schema di `rate_limit_event` e il formato stream-json sono comportamenti osservati sulla CLI **2.1.258**, non API garantite. Un aggiornamento della CLI può romperli in silenzio | Parser tollerante (come già fa `UsageModel` con `rl.json`), degradazione esplicita invece di crash, e un test che gira contro la CLI installata e fallisce rumorosamente se lo schema cambia |

## Nota di licenza

Il repo di **Natively** è stato clonato come riferimento architetturale. La sua licenza
(Natively Personal Use Source License v1.0) è *source-available*, non open source, e
vieta esplicitamente uso commerciale e client work. Matteo ha contattato il dev e ha
conferma per il proprio caso studio personale.

Resta un vincolo pratico da rispettare: **Meowtch è MIT e pubblica** (release GitHub +
`install.sh`). Le *idee* architetturali si riusano liberamente; **copiare codice** di
Natively in un repo MIT creerebbe un conflitto reale, perché MIT concede a valle l'uso
commerciale che quella licenza nega. Riferimento sì, copia-incolla no.

Licenze verificate via API GitHub (i README non sono affidabili su questo): riusabili come
codice sono **OpenCluely e Vysper, entrambi Apache-2.0** — il README di OpenCluely dice MIT, il
file LICENSE dice Apache-2.0 — e hiddenai (MIT). **Glass e cue sono GPL-3.0**, contagiose.
**Pluely è un caso ambiguo**: il LICENSE nel repo è GPL-3.0, ma README e sito dichiarano v1
proprietaria. Da trattare come non riusabile finché la contraddizione non è risolta.
Dato che tutto va comunque reimplementato in Swift, il punto è in gran parte accademico.
