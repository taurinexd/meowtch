# CALL mode — copilota con preparazione, ricerca nel codice e registrazione

Integra e in parte sostituisce `2026-09-02-call-mode-design.md`. Quello spec resta valido
per audio, trascrizione, trigger, consumi, privacy e motori; questo documento cambia ciò che
Matteo ha chiesto il 2026-11-16 e definisce la superficie, che lì era solo accennata.
Mockup approvati: `2026-11-16-call-mode-mockups.html`, qui accanto (1a, 1b, 2a, 2b, 2c, 4).

## Perché

Durante una call con un cliente (esempio: Acme Impianti) Matteo vuole due cose:

1. **Suggerimenti a testo nella notch** su cosa rispondere quando gli fanno una domanda,
   basati su cosa ha già detto lui, sul contesto del cliente e sul **materiale che ha sul
   Mac**: documenti nelle cartelle del progetto e codice. Il copilota deve capire da solo
   cosa andare a leggere.
2. **La call registrata** nella cartella del progetto, sul suo computer.

## Obiettivi, non obiettivi, anti-obiettivi

**Obiettivi**
- Suggerimento leggibile con la coda dell'occhio entro 1–2 s dalla fine della domanda.
- Quando la domanda chiede un fatto, una verifica in codice e documenti che arriva dopo,
  sotto il suggerimento, con le fonti.
- Un cliente = più cartelle, scelte una volta e ricordate.
- A fine call: testo della call salvato nella cartella del cliente, scheda cliente
  aggiornata solo con approvazione.

**Non obiettivi**
- Accesso a prod (database, API, ClickUp) dalla ricerca: **escluso** (decisione 2026-11-16).
  Solo file locali.
- Registrazione audio: si salva solo testo.
- Whisper: la trascrizione resta `SpeechTranscriber` di Apple in locale (spec 09-02 §2).

**Anti-obiettivi** (sarebbe un fallimento anche se funziona)
- Un suggerimento rapido sbagliato che la verifica contraddice **senza dirlo chiaramente**.
- Registrazioni o scheda cliente che finiscono in un commit.
- Il copilota che legge o scrive fuori dalle cartelle del cliente.
- Una ricerca che arriva quando la conversazione è già due domande più avanti e si
  presenta come se fosse la risposta alla domanda corrente.

## Cosa cambia rispetto allo spec 09-02

| Tema | 09-02 | Ora |
|---|---|---|
| Trascritto | muore in RAM, niente su disco | salvato come testo in `<principale>/.meowtch/calls/` |
| Contesto | `webgas.md` + `client.md`, nessun tool | + **riassunto di preparazione** (brief) + **ricerca approfondita** con lettura file |
| Cartella cliente | una sola | **profilo cliente** con più cartelle, una principale |
| Motori in call | una sessione `claude` senza tool | **due corsie**: rapida (senza tool) e approfondita (sola lettura file) |
| UI | accennata | definita dai mockup approvati |

Tutto il resto dello spec 09-02 resta com'è: cattura audio a due canali (process tap +
microfono), cuffie come precondizione, endpointing semantico, trigger che non chiama mai il
motore, tre soppressioni, hotkey di override, consumi da `rate_limit_event`, auto-switch a
Ollama, emendamento no-telemetry, metriche.

## Approcci considerati

1. **Solo preparazione prima della call.** Risposte in 1–2 s, ma niente di ciò che non era
   previsto.
2. **Solo ricerca in diretta.** Più preciso sulle domande inattese, ma 10–20 s per ogni
   risposta, spesso a domanda già passata.
3. **Tutte e due (scelto).** Corsia rapida da ciò che è già stato letto, e in parallelo,
   solo se serve, una corsia approfondita che verifica in codice e documenti. Scelto perché
   è l'unico che tiene la latenza bassa senza rinunciare alla verifica.

Per prod erano state valutate tre vie (niente / comandi scelti / utente DB di sola lettura):
scelto **niente prod** per ora.

## Profilo cliente

```
~/.vedetta/call/clients/<slug>.json
{
  "name": "Acme Impianti",
  "folders": [
    {"path": "~/Code/acme-site", "primary": true},
    {"path": "~/Code/acme-migration"},
    {"path": "~/Code/acme-checkout"},
    {"path": "~/Code/platform", "include": ["docs/**", "app/Commerce/**"]}
  ]
}
```

- La cartella **principale** ospita `.meowtch/` (scheda, brief, registrazioni).
- `include` facoltativo per cartelle grandi condivise fra clienti (es. `platform`).
- Esclusi sempre: `.git`, `node_modules`, `vendor`, `dist`, `.build`, file binari, segreti
  (`.env*`, `*.pem`, `*.key`, credenziali): non entrano nel brief né nella ricerca.
- `.meowtch/` va in `.git/info/exclude` della cartella principale (regola e casi limite già
  nello spec 09-02: cartella non versionata, worktree).

## Preparazione (brief)

- **Quando:** pulsante «Prepara / Aggiorna» nella schermata 1a. Si può iniziare la call
  prima che finisca (1b, «Inizia comunque»).
- **Come:** un `claude -p` una tantum con `--tools Read Grep Glob`, `--add-dir` sulle
  cartelle del profilo, cwd neutra `~/.vedetta/call/` (niente `AGENTS.md`/`CLAUDE.md`
  ereditati, motivo nello spec 09-02). Istruzioni: produrre un riassunto orientato alle
  domande che un cliente può fare (stato dei lavori, decisioni, limiti noti, cose
  promesse, numeri chiave), con il percorso del file per ogni fatto.
- **Output:** `<principale>/.meowtch/brief.md` + `brief.manifest.json` (percorso e mtime di
  ogni file letto).
- **Freschezza:** all'apertura del profilo si confronta il manifest con il disco → «3 file
  cambiati da allora». Nessun aggiornamento automatico: costa, lo decide Matteo.
- **Costo e progresso** visibili (1b): file in lettura, token, $.

## Corsia rapida

- La sessione persistente dello spec 09-02 (`--tools ""`, stream-json, un processo per call),
  con `webgas.md` + `client.md` + `brief.md` in `--append-system-prompt`.
- Output richiesto: la frase da dire (massimo 2 righe o 3 punti, italiano parlato), poi una
  riga finale di controllo che la UI non mostra: `VERIFICA: no` oppure
  `VERIFICA: <cosa cercare>`. Se il parser non trova la riga, si assume `no`.

## Corsia approfondita

- **Parte solo** quando la corsia rapida chiede `VERIFICA: …` oppure su hotkey con modifica
  (⌥⇧ Spazio = «rispondi e verifica»).
- **Processo:** una seconda sessione `claude` persistente per call (stesso motivo di costo
  dello spec 09-02 §5), `--tools Read Grep Glob`, `--add-dir` sulle cartelle del profilo,
  cwd neutra. Riceve: domanda, suggerimento rapido, cosa verificare.
- **Risposta** in tre campi: esito (`conferma` / `precisa` / `contraddice`), testo breve,
  fonti come `percorso:riga`.
- **Una sola ricerca alla volta.** Se ne arriva un'altra mentre una gira, resta in coda solo
  l'ultima: quelle intermedie si scartano.
- **Legata alla sua domanda.** Il risultato si mostra sotto la domanda che l'ha generata. Se
  nel frattempo c'è una domanda nuova, finisce nel filo, segnata «verifica per la domanda
  precedente», e non sostituisce il suggerimento corrente.
- **Contraddizione esplicita:** con esito `contraddice` la riga viola apre con
  «Attenzione: …» e la notch chiusa mostra lo stato «verificato» in arancione invece che
  in viola.
- Tempo massimo per ricerca: costante nominata, default 45 s; oltre si mostra «non trovato».

## Superficie (mockup approvati)

- **1a Prima della call:** scelta cliente (ultimi usati), cartelle del profilo con la
  principale evidenziata, stato del brief, controlli (cuffie, microfono e audio del meeting,
  invisibilità, dove si registra), consumi, «Inizia ad ascoltare».
- **1b Preparazione in corso:** elenco di ciò che sta leggendo, barra, token e $,
  «Inizia comunque».
- **Durante:** di default **2a + 2b**: «Ti hanno chiesto», «Puoi dire» grande, sotto la
  verifica con le fonti. Il **filo della conversazione (2c) è a scomparsa**, chiuso di
  default e apribile con un clic (stesso schema dell'accordion delle tasks). Barra in basso:
  ⌥ Spazio, durata e token della risposta, costo della call, finestra 5h.
- **Notch chiusa:** in ascolto / sto preparando / «Di' questo» / verificato (scelta di
  progetto: i mockup non sono stati né scelti né scartati).
- **4 Fine call:** dove è stata salvata, diff proposto della scheda cliente, «Scarta» /
  «Aggiorna scheda» / «Apri registrazione».

## Registrazione

- File: `<principale>/.meowtch/calls/YYYY-MM-DD-HHmm.md`, scritto **in aggiunta durante la
  call** (un crash non perde la parte già detta).
- Contenuto: intestazione (cliente, inizio, durata, costo), battute con orario e
  «Cliente» / «Matteo» dal canale, ogni suggerimento rapido e ogni verifica con fonti sotto
  la battuta che li ha generati.
- Solo testo, niente audio. Resta solo sul Mac di Matteo; avvisare i partecipanti che la
  call è trascritta è responsabilità sua (non è un problema tecnico).

## Ordine di costruzione

1. **Spike audio + trascrizione** (dallo spec 09-02): process tap su Meet + microfono,
   `SpeechTranscriber` it-IT, verifica della punteggiatura interrogativa con audio reale.
2. **Corsia rapida + UI 2a + hotkey**, senza brief (solo `client.md`).
3. **Profili cliente + brief** (1a, 1b).
4. **Corsia approfondita** (2b) con regole di coda e contraddizione.
5. **Registrazione + scheda a fine call** (4).
6. **Filo a scomparsa, stati della notch chiusa, rifiniture.**

Ogni passo si verifica con una call reale o simulata (audio di sistema da un video), non
solo con i test.

## Scelte di progetto (non discusse, correggibili)

- Modelli: corsia rapida sul modello più veloce disponibile, corsia approfondita e brief sul
  modello di default (il tiering è nello spec 09-02).
- ⌥⇧ Spazio come hotkey per «rispondi e verifica».
- Stati della notch chiusa come da mockup 3.
- Tempo massimo della ricerca: 45 s.

## Lasciato a chi costruisce

- Prompt esatti di brief, corsia rapida e corsia approfondita.
- Formato interno del manifest e dei messaggi stream-json.
- Soglie di endpointing (costanti nominate, come da spec 09-02).
- Limite di dimensione del brief e strategia se le cartelle sono enormi (taglio per
  rilevanza, non per ordine alfabetico).
