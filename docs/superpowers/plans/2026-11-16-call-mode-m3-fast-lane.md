# CALL mode M3 — corsia rapida Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** mentre Meowtch ascolta una call, quando il cliente finisce una domanda la notch mostra «They asked» + «You can say» in streaming entro 1–2 s, generato da una sessione `claude` persistente senza tool; ⌥ Spazio forza la risposta.

**Architecture:** decisione e generazione separate (spec 09-02 §«Confini»). In `VedettaKit`, puro e testato: turni e domanda pendente, trigger (endpointing + marcatori + tre soppressioni), coda «solo l'ultima», parser stream-json, prompt, metriche. In `Vedetta`: processo `claude` per call (`ClaudeCallEngine`), orchestratore `CallCopilot` che campiona il trascritto ogni 250 ms, hotkey Carbon, UI 2a dentro `CallListenView`.

**Tech Stack:** Swift 6, SwiftUI/AppKit, Carbon `RegisterEventHotKey`, `Process` + pipe stdin/stdout, Swift Testing.

**Spec:** `docs/superpowers/specs/2026-11-16-call-mode-copilot-design.md` (ordine di costruzione, passo 2) + `docs/superpowers/specs/2026-09-02-call-mode-design.md` (trigger, motore, consumi, privacy, metriche).

## Global Constraints

- Passo 2 dello spec: **corsia rapida + UI 2a + hotkey, senza brief**; contesto = `~/.vedetta/call/webgas.md` + `<cartella cliente>/.meowtch/client.md`. Niente profili, brief, corsia approfondita, registrazione (passi 3–5).
- Fuori da M3 anche: auto-switch a Ollama e budget, `rate_limit_event` come terza fonte di `UsageModel`, stati della notch chiusa, `false_trigger_rate`/`premature_trigger_rate` (servono etichette a mano: si contano nella prova reale del Task 5).
- «Il trigger non chiama mai il motore di risposta» · «Due risposte non vanno mai in streaming insieme» (si accoda solo l'ultima) · si misurano `endpoint → decision` e `decision → first token`.
- Processo: un `claude` per call, mai uno per risposta. Flag: `-p --input-format stream-json --output-format stream-json --verbose --include-partial-messages --tools "" --restricted --strict-mcp-config --no-session-persistence --model haiku --append-system-prompt <prompt>`, cwd `~/.vedetta/call/` (creata se manca), `CLAUDE_CONFIG_DIR` rimosso dall'ambiente (account di default, vedi memoria `claude-config-dir-keychain-namespacing`).
- Formato misurato il 2026-11-16 su CLI 2.1.325 (haiku, 0,0005 $ a risposta): input `{"type":"user","message":{"role":"user","content":"…"}}` una riga per messaggio; output `stream_event` con `event.type == "content_block_delta"` e `event.delta.type == "text_delta"`; `result` con `subtype`, `is_error`, `result`, `total_cost_usd` **per turno** (si sommano), `duration_ms`, `usage.output_tokens`; `rate_limit_event` porta **una sola** finestra in `unifiedWindows` (visto solo `seven_day`): non è una fonte affidabile del 5h, quindi la barra legge `UsageModel.shared.fiveHour`.
- Output richiesto al modello: la frase da dire (max 2 righe o 3 punti, italiano parlato), poi l'ultima riga `VERIFICA: no` oppure `VERIFICA: <cosa cercare>`; la UI non la mostra mai, nemmeno a metà streaming; riga assente = `no`.
- **Consenso (emendamento no-telemetry, spec 09-02 §Privacy):** i suggerimenti mandano il trascritto ad Anthropic → interruttore `callSuggestionsEnabled`, **spento di default**, che è anche il kill-switch (spegnerlo termina il processo). Con l'interruttore spento nessun processo parte. `AGENTS.md` va emendato.
- Hotkey ⌥ Spazio = «rispondi ora», registrata solo mentre si ascolta con i suggerimenti accesi (fuori dalla call ⌥ Spazio resta del sistema).
- Copy dell'app in inglese come il resto di Meowtch («They asked», «You can say», «answer now»); il suggerimento è in italiano. Registro impersonale, niente prima persona dell'app.
- Processi: si termina solo il `Process` posseduto (`terminate()` sul proprio PID), mai `pkill` per nome.

## Review Focus

1. Affermazione del cliente senza «?» né marcatore («Il carrello lo abbiamo provato ieri») → nessun suggerimento (test in Task 1).
2. Pausa a metà frase che finisce con «e», «che», «per» → nessun trigger finché non riprende e chiude (test in Task 1).
3. Matteo che inizia a rispondere → nessun suggerimento e la domanda risulta consumata, non riproposta dopo (test in Task 1).
4. Il processo `claude` che muore a metà call (logout, crash, binario mancante) → messaggio visibile nella notch, mai silenzio; la domanda successiva riavvia il processo (test del parser in Task 2, comportamento in Task 3).
5. Riga `VERIFICA` parziale (`VERIF`, `VERIFICA: cer`) durante lo streaming → mai visibile (test in Task 2).

---

### Task 1: Turni, trigger e coda (VedettaKit)

**Files:**
- Create: `App/Sources/VedettaKit/CallTurns.swift`, `App/Sources/VedettaKit/AnswerTrigger.swift`
- Test: `App/Tests/VedettaKitTests/CallTurnsTests.swift`, `App/Tests/VedettaKitTests/AnswerTriggerTests.swift`

**Interfaces:**
- Consumes: `CallTranscript`, `CallLine`, `CallSpeaker` (M2).
- Produces:
  - `public struct CallTurns: Sendable` — `init()`, `func pending(in: CallTranscript) -> String` (testo del cliente non ancora consumato, righe unite da spazio, trim), `mutating func consumeAll(in: CallTranscript)` (tutto ciò che il cliente ha detto finora è consumato: le righe chiuse per id, quella aperta per numero di caratteri già visti), `func lastClientText(in: CallTranscript, lines: Int) -> String` (per l'hotkey quando `pending` è vuoto).
  - `public struct TriggerInput: Sendable` — `pending: String`, `now: Date`, `lastClientActivity: Date?`, `lastMeActivity: Date?`, `answered: [String]`.
  - `public enum TriggerDecision: Equatable, Sendable` — `.wait`, `.fire(question: String, endpointAt: Date)`, `.consume(reason: SuppressReason)`; `public enum SuppressReason: String, Sendable { case meSpeaking, duplicate }`.
  - `public enum AnswerTrigger` — `static func decide(_ input: TriggerInput) -> TriggerDecision`; costanti nominate `silenceAfterQuestionMark: TimeInterval = 0.6`, `silenceAfterMarker = 1.0`, `meSpeakingWindow = 1.5`, `minimumWords = 3`, `duplicateSimilarity = 0.8`; `static func isNearDuplicate(_ a: String, _ b: String) -> Bool` (Jaccard sulle parole normalizzate: minuscole, senza punteggiatura).
  - `public struct LatestOnlyQueue<Item: Sendable>: Sendable` — `mutating func submit(_ item: Item) -> Item?` (restituisce l'item se il motore è libero e lo segna occupato, altrimenti lo tiene come unico in attesa sostituendo il precedente), `mutating func finish() -> Item?` (libera e restituisce l'eventuale in attesa, segnandolo occupato), `var isBusy: Bool`.

Regole di `decide`, in quest'ordine:
1. `pending` vuoto o meno di `minimumWords` parole → `.wait`.
2. Matteo attivo dopo l'ultima attività del cliente, oppure entro `meSpeakingWindow` da `now` → `.consume(.meSpeaking)` (sta già rispondendo).
3. `isNearDuplicate` con una qualunque di `answered` → `.consume(.duplicate)`.
4. Ultima parola in `truncationEndings` (e, ed, ma, che, di, del, della, per, con, a, al, in, il, la, lo, i, gli, le, un, una, o, se, quindi, però, cioè, tipo, ehm) → `.wait`.
5. Silenzio del cliente (`now - lastClientActivity`): testo che finisce con «?» e silenzio ≥ `silenceAfterQuestionMark` → `.fire`; altrimenti testo che contiene un marcatore (chi, cosa, come, quando, quanto, quanti, quante, perché, quale, quali, dove) o apre con un attacco modale (potete, potreste, puoi, potresti, riuscite, riesci, avete, hai, sapete, sai, è possibile, si può, ci sono, c'è, mi sai dire, mi dici) e silenzio ≥ `silenceAfterMarker` → `.fire`; altrimenti `.wait`. `endpointAt` = `lastClientActivity`.

Le domande chiuse senza attacco modale non scattano: le copre ⌥ Spazio (classificatore rimandato, vedi spec 09-02 §Rischi).

- [ ] **Step 1: Write the failing tests**

```swift
// CallTurnsTests
@Test func pendingIsClientTextAfterTheMark() {
    var t = CallTranscript(); let t0 = Date()
    t.apply(.init(speaker: .client, text: "Buongiorno a tutti", isFinal: true, at: t0))
    var turns = CallTurns(); turns.consumeAll(in: t)
    t.apply(.init(speaker: .client, text: "Il carrello funziona già?", isFinal: false, at: t0 + 2))
    #expect(turns.pending(in: t) == "Il carrello funziona già?")
}
@Test func consumeAllCutsTheOpenLineByCharacters() {
    var t = CallTranscript(); let t0 = Date()
    t.apply(.init(speaker: .client, text: "Quando consegnate?", isFinal: false, at: t0))
    var turns = CallTurns(); turns.consumeAll(in: t)
    t.apply(.init(speaker: .client, text: "Quando consegnate? E quanto costa?", isFinal: false, at: t0 + 3))
    #expect(turns.pending(in: t) == "E quanto costa?")
}
@Test func myLinesNeverCountAsPending() { /* solo righe .me → pending == "" */ }
@Test func lastClientTextJoinsTheLastClientLines() { /* 3 righe cliente, lines: 2 → ultime due unite */ }

// AnswerTriggerTests — helper: input(pending:, clientSilence:, meAgo: nil, answered: [])
@Test func questionMarkFiresAfterShortSilence() {
    #expect(AnswerTrigger.decide(input("Quando consegnate il checkout?", clientSilence: 0.7)) ==
            .fire(question: "Quando consegnate il checkout?", endpointAt: /* now - 0.7 */))
    #expect(AnswerTrigger.decide(input("Quando consegnate il checkout?", clientSilence: 0.3)) == .wait)
}
@Test func markerWithoutQuestionMarkNeedsLongerSilence() {
    #expect(AnswerTrigger.decide(input("Quanto costa la migrazione", clientSilence: 0.8)) == .wait)
    if case .fire = AnswerTrigger.decide(input("Quanto costa la migrazione", clientSilence: 1.1)) {} else { Issue.record("no fire") }
}
@Test func modalOpenerCountsAsQuestion() { /* "Riuscite a farlo entro giugno", silence 1.1 → .fire */ }
@Test func statementNeverFires() { /* "Il carrello lo abbiamo provato ieri", silence 5 → .wait */ }
@Test func truncatedSentenceWaits() { /* "Quanto costa la migrazione e", silence 3 → .wait */ }
@Test func tooShortWaits() { /* "Come?", silence 2 → .wait */ }
@Test func meSpeakingConsumes() {
    #expect(AnswerTrigger.decide(input("Quando consegnate?", clientSilence: 2, meAgo: 0.5)) == .consume(reason: .meSpeaking))
}
@Test func duplicateConsumes() {
    #expect(AnswerTrigger.decide(input("Quando consegnate il checkout?", clientSilence: 1,
        answered: ["quando consegnate il checkout"])) == .consume(reason: .duplicate))
}
@Test func latestOnlyQueueKeepsOnlyTheLastWaiting() {
    var q = LatestOnlyQueue<String>()
    #expect(q.submit("a") == "a"); #expect(q.submit("b") == nil); #expect(q.submit("c") == nil)
    #expect(q.finish() == "c"); #expect(q.isBusy); #expect(q.finish() == nil); #expect(!q.isBusy)
}
```

- [ ] **Step 2: Run to verify they fail** — `make test 2>&1 | tail -20` → Expected: build error, `CallTurns` / `AnswerTrigger` / `LatestOnlyQueue` not found.
- [ ] **Step 3: Implement** the interfaces above in the two files (`LatestOnlyQueue` lives in `AnswerTrigger.swift`).
- [ ] **Step 4: Run** — `make test 2>&1 | tail -5` → Expected: all green, count = 279 + new tests.
- [ ] **Step 5: Commit** — `feat(call): turns, answer trigger and latest-only queue`

---

### Task 2: Stream-json, prompt, risposta rapida e metriche (VedettaKit)

**Files:**
- Create: `App/Sources/VedettaKit/ClaudeStream.swift`, `App/Sources/VedettaKit/CallCopilotPrompt.swift`, `App/Sources/VedettaKit/QuickAnswer.swift`, `App/Sources/VedettaKit/CallMetrics.swift`
- Test: `App/Tests/VedettaKitTests/ClaudeStreamTests.swift`, `CallCopilotPromptTests.swift`, `QuickAnswerTests.swift`, `CallMetricsTests.swift`

**Interfaces:**
- Produces:
  - `public enum ClaudeStreamEvent: Equatable, Sendable` — `.textDelta(String)`, `.result(ClaudeTurnResult)`, `.other`; `public struct ClaudeTurnResult: Equatable, Sendable { isError: Bool; text: String; costUSD: Double; durationMs: Int; outputTokens: Int }`.
  - `public enum ClaudeStream` — `static func parse(line: String) -> ClaudeStreamEvent` (tollerante: JSON non valido o campi mancanti → `.other`, mai crash); `static func userLine(_ content: String) -> String` (una riga JSON, terminata da `\n`, con escape corretto di virgolette e a capo).
  - `public enum CallCopilotPrompt` — `static func system(webgas: String?, client: String?) -> String`; `static func userMessage(question: String, recent: [CallLine]) -> String`; `static let contextLimit = 20_000` (caratteri per file; oltre si tronca con la riga `[…troncato]`).
  - `public enum QuickAnswer` — `static func visible(_ streaming: String) -> String` (testo senza riga `VERIFICA` completa o parziale: si taglia dall'ultima riga che, senza spazi iniziali, è prefisso di `"VERIFICA:"` o inizia con `"VERIFICA"`, case-insensitive); `static func verify(_ final: String) -> String?` (nil per `no` o riga assente, altrimenti il testo dopo i due punti, trim).
  - `public struct CallMetrics: Sendable` — `mutating func recordDecision(endpointToDecisionMs: Int)`, `mutating func recordFirstToken(decisionToFirstTokenMs: Int)`, `mutating func recordOverride()`, `func snapshot() -> [String: Int]` con chiavi `endpoint_to_decision_ms_median`, `endpoint_to_decision_ms_p95`, `decision_to_first_token_ms_median`, `manual_override_count`, `trigger_count` (assenti finché non ci sono campioni; p95 = nearest-rank).

Contenuto pinnato del prompt di sistema (il testo esatto è di chi costruisce): sei il copilota di Matteo, sviluppatore di Webgas, in una call con un cliente; rispondi con ciò che Matteo può dire ad alta voce, in italiano parlato, prima persona di Matteo, massimo 2 righe o 3 punti; mai inventare numeri, date o stati dei lavori che non sono nel contesto: in quel caso suggerisci di verificare e far sapere; ultima riga sempre `VERIFICA: no` o `VERIFICA: <cosa cercare in codice o documenti>`. Seguono, se presenti, `## Contesto Webgas` e `## Scheda cliente`. `userMessage`: blocco `Conversazione recente:` con righe `Cliente: …` / `Matteo: …` (solo righe finali o aperte, nell'ordine), poi riga vuota e `Domanda del cliente: «<question>»`.

- [ ] **Step 1: Write the failing tests** — righe reali catturate da CLI 2.1.325:

```swift
@Test func parsesTextDelta() {
    let line = #"{"type":"stream_event","event":{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"ok"}}}"#
    #expect(ClaudeStream.parse(line: line) == .textDelta("ok"))
}
@Test func parsesResult() {
    let line = #"{"type":"result","subtype":"success","is_error":false,"duration_ms":1088,"result":"ok","total_cost_usd":0.00049058,"usage":{"output_tokens":4}}"#
    #expect(ClaudeStream.parse(line: line) == .result(.init(isError: false, text: "ok", costUSD: 0.00049058, durationMs: 1088, outputTokens: 4)))
}
@Test func rateLimitAndGarbageAreOther() {
    #expect(ClaudeStream.parse(line: #"{"type":"rate_limit_event","rate_limit_info":{"unifiedWindows":{"seven_day":{"utilization":0.4}}}}"#) == .other)
    #expect(ClaudeStream.parse(line: "not json") == .other)
}
@Test func errorResultIsFlagged() { /* {"type":"result","subtype":"error_during_execution","is_error":true} → isError true, campi mancanti a 0/"" */ }
@Test func userLineRoundTrips() {
    let line = ClaudeStream.userLine("Riga «uno»\n\"due\"")
    #expect(line.hasSuffix("\n")); #expect(!line.dropLast().contains("\n"))
    // decodificata con JSONSerialization: type == "user", message.content == input
}
@Test func visibleHidesPartialAndFullVerifyLine() {
    #expect(QuickAnswer.visible("Sì, entro giugno.\nVERIF") == "Sì, entro giugno.")
    #expect(QuickAnswer.visible("Sì, entro giugno.\nVERIFICA: cer") == "Sì, entro giugno.")
    #expect(QuickAnswer.visible("Sì, entro giugno.\nV") == "Sì, entro giugno.")
    #expect(QuickAnswer.visible("Va bene, ci sentiamo") == "Va bene, ci sentiamo")
}
@Test func verifyReadsTheLastLine() {
    #expect(QuickAnswer.verify("Sì.\nVERIFICA: no") == nil)
    #expect(QuickAnswer.verify("Sì.") == nil)
    #expect(QuickAnswer.verify("Sì.\nVERIFICA: stato del checkout misto") == "stato del checkout misto")
}
@Test func systemPromptCarriesContextAndTruncates() {
    let p = CallCopilotPrompt.system(webgas: "W", client: String(repeating: "x", count: 25_000))
    #expect(p.contains("VERIFICA")); #expect(p.contains("## Contesto Webgas")); #expect(p.contains("[…troncato]"))
    #expect(!CallCopilotPrompt.system(webgas: nil, client: nil).contains("## Scheda cliente"))
}
@Test func userMessageLabelsSpeakers() { /* righe client/me → "Cliente: …", "Matteo: …", poi "Domanda del cliente: «…»" */ }
@Test func metricsMedianAndP95() {
    var m = CallMetrics(); [100, 200, 300, 400, 1000].forEach { m.recordDecision(endpointToDecisionMs: $0) }
    #expect(m.snapshot()["endpoint_to_decision_ms_median"] == 300)
    #expect(m.snapshot()["endpoint_to_decision_ms_p95"] == 1000)
    #expect(m.snapshot()["trigger_count"] == 5)
}
```

- [ ] **Step 2: Run** — `make test 2>&1 | tail -20` → Expected: build error, types not found.
- [ ] **Step 3: Implement** the four files.
- [ ] **Step 4: Run** — `make test 2>&1 | tail -5` → Expected: all green.
- [ ] **Step 5: Commit** — `feat(call): stream-json parsing, copilot prompt, quick answer and metrics`

---

### Task 3: Motore `claude` per call

**Files:**
- Create: `App/Sources/Vedetta/Call/ClaudeCallEngine.swift`
- Modify: `App/Sources/Vedetta/Settings/SettingsDefaults.swift` (chiavi `callSuggestionsEnabled` default `false`, `callClientFolder` default assente), `App/Sources/Vedetta/EventDispatcher.swift` (comando debug `callAsk`)

**Interfaces:**
- Consumes: `ClaudeStream`, `CallCopilotPrompt` (Task 2); `ClaudeCLI.resolve()`, `ClaudeCLI.shellArguments(_:_:)`.
- Produces: `final class ClaudeCallEngine: @unchecked Sendable` — `init(onEvent: @escaping @Sendable (ClaudeStreamEvent) -> Void, onExit: @escaping @Sendable (String) -> Void)`; `func start(systemPrompt: String) throws` (lancia il processo con i flag di Global Constraints; errore `CallEngineError.claudeNotFound` se `resolve()` è nil); `func send(_ userMessage: String)` (scrive `ClaudeStream.userLine` su stdin; se il processo non è vivo lo riavvia con l'ultimo prompt prima di scrivere); `func stop()` (chiude stdin, `terminate()` sul proprio processo); `var isRunning: Bool`. `onExit` riceve la coda di stderr (ultime 300 battute) quando il processo esce senza `stop()`.
- Contesto: `static func loadContext(clientFolder: URL?) -> (webgas: String?, client: String?)` legge `~/.vedetta/call/webgas.md` e `<clientFolder>/.meowtch/client.md` se esistono; solo lettura.

- [ ] **Step 1: Implement** engine, chiavi e comando `callAsk` (`{"cmd":"callAsk","value":"<domanda>"}` → avvia il motore se serve, manda `userMessage(question:recent: [])`, risponde `{"ok":true}`; gli eventi si leggono col comando di Task 4). Lettura di stdout riga per riga su un thread dedicato; ogni riga → `ClaudeStream.parse` → `onEvent`.
- [ ] **Step 2: Build** — `make app 2>&1 | tail -3` → Expected: `Built …/dist/Meowtch.app`.
- [ ] **Step 3: Verify live** — riavvio dell'app (solo il proprio PID, poi `open dist/Meowtch.app`); `sock.py '{"cmd":"callAsk","value":"Quando consegnate il checkout?"}'`; in un log temporaneo (`NSLog` nel callback, rimosso prima del commit) si vedono `textDelta` e un `result` con `isError false`. Poi `ps -o pid,args` mostra un solo processo `claude` figlio dell'app con `--tools  --model haiku`; un secondo `callAsk` non crea un secondo processo.
- [ ] **Step 4: Verify failure path** — `kill <pid del claude figlio>` (PID letto da `ps`, mai per nome) → `onExit` chiamato; il `callAsk` successivo riavvia e risponde.
- [ ] **Step 5: Commit** — `feat(call): one claude process per call for quick answers`

---

### Task 4: `CallCopilot` — orchestrazione, consenso, hotkey

**Files:**
- Create: `App/Sources/Vedetta/Call/CallCopilot.swift`, `App/Sources/Vedetta/Call/CallHotKey.swift`
- Modify: `App/Sources/Vedetta/Call/CallSession.swift` (espone `lastLoudClient`/`lastLoudMe: Date?` aggiornati quando l'RMS del buffer ≥ `CallCopilot.speechRMS = 0.02`; avvia/ferma il copilota con l'ascolto), `App/Sources/Vedetta/EventDispatcher.swift` (comando debug `callCopilot`)

**Interfaces:**
- Consumes: tutto Task 1–3; `CallSession.shared.transcript`, `isListening`.
- Produces: `@MainActor final class CallCopilot: ObservableObject` con `static let shared`; `@Published` `question: String?`, `answer: String` (già filtrato da `QuickAnswer.visible`), `isStreaming: Bool`, `elapsed: TimeInterval`, `outputTokens: Int` (stima live = delta ricevuti / 4 caratteri, sostituita dal valore del `result`), `callCostUSD: Double`, `engineProblem: String?`, `verifyHint: String?` (conservato per il passo 4, non mostrato); `func start()`, `func stop()`, `func answerNow()` (hotkey: domanda = `pending`, o `lastClientText(lines: 2)` se vuoto; salta il trigger; `recordOverride()`); `var metrics: CallMetrics`.
- `CallHotKey`: `init(keyCode: UInt32 = kVK_Space, modifiers: UInt32 = optionKey, action: @escaping @MainActor () -> Void)`, `register()`, `unregister()` via `RegisterEventHotKey` / `UnregisterEventHotKey`.

Comportamento:
- `start()` solo se `callSuggestionsEnabled` è vero: avvia il motore con `CallCopilotPrompt.system(loadContext)`, registra la hotkey, timer 250 ms. Altrimenti non fa nulla. Spegnere l'interruttore durante l'ascolto → `stop()` (kill-switch).
- A ogni tick: `AnswerTrigger.decide` con `pending`, attività (max fra ultimo update della riga del canale e `lastLoud…`), `answered`. `.fire` → `turns.consumeAll`, `answered.append`, `recordDecision`, coda `submit`; `.consume` → `turns.consumeAll`.
- Invio: `question` = domanda, `answer` = "", `isStreaming` = true, cronometro; primo `textDelta` → `recordFirstToken`. `result` → `verifyHint = QuickAnswer.verify(text)`, costo sommato, `isStreaming` false, `queue.finish()` → eventuale domanda in attesa.
- `result` con `isError` o `onExit` → `engineProblem = "Suggestions stopped: <motivo breve>. The next question restarts them."`, `isStreaming` false, coda liberata.
- `callCopilot` (debug) restituisce `question`, `answer`, `streaming`, `costUSD`, `problem`, `metrics.snapshot()`.

- [ ] **Step 1: Implement** come sopra.
- [ ] **Step 2: Build** — `make app 2>&1 | tail -3` → Expected: `Built …`.
- [ ] **Step 3: Verify consent off** — interruttore spento (default), `callListen true` + `callTranscribeFile` su `scratchpad/callaudio/q20.aiff` → nessun processo `claude` figlio in `ps`; `callCopilot` → `question` null.
- [ ] **Step 4: Verify end to end** — `defaults write app.vedetta.macos callSuggestionsEnabled -bool true`, riavvio, stesso file → entro 1–2 s dalla fine di ogni domanda con «?» `callCopilot` mostra `question` e `answer` in italiano senza `VERIFICA`; `metrics` con mediane valorizzate. Annotare nell'audit `endpoint_to_decision_ms` e `decision_to_first_token_ms` misurati e quante delle 20 domande sono scattate.
- [ ] **Step 5: Verify hotkey** — ⌥ Spazio sintetico **solo** dopo aver controllato che l'app è in esecuzione e la notch è in CALL in ascolto (lezione M2: input sintetico mai a vuoto) → `manual_override_count` 1. A ascolto fermo ⌥ Spazio non è registrata (`callCopilot` invariato).
- [ ] **Step 6: Commit** — `feat(call): copilot decides, asks and streams quick answers`

---

### Task 5: UI 2a, interruttore, cartella cliente, contratto

**Files:**
- Modify: `App/Sources/Vedetta/UI/CallListenView.swift`, `AGENTS.md` (regola «No telemetry»), `docs/vi-binary-audit.md` (sezione «CALL mode M3» con le misure)

**Interfaces:**
- Consumes: `CallCopilot.shared` (Task 4), `UsageModel.shared.fiveHour?.percent`, `Theme`.

Layout (mockup 2a, copy inglese):
- Con `question`: riquadro «They asked» (etichetta piccola grigia, domanda tra « » in 12 pt), poi «You can say» (etichetta arancione `Theme.claudeOrange`, testo 14 pt semibold, max 4 righe; durante lo streaming un cursore `▍`).
- Barra in fondo: tasto `⌥ Space` + «answer now» a sinistra; a destra `3.1s · ↓ 212 tokens` mentre risponde, poi `call $0.18 · 5h 38%` (5h omesso se `fiveHour` è nil).
- `engineProblem` come riga rossa con la funzione `notice` esistente.
- Interruttore suggerimenti, sopra il trascritto: spento → «Suggestions are off. When on, the transcript is sent to Claude (Anthropic) to suggest answers.» + pulsante «Turn on»; acceso → piccolo pulsante «Turn off». Scrive `callSuggestionsEnabled`.
- Cartella cliente: riga «Client: <nome cartella>» o «Client: none» con pulsante «Choose…» → `NSOpenPanel` (solo cartelle; `NSApp.activate` prima) → `callClientFolder`. Nessuna scrittura nella cartella.
- Il trascritto resta sotto, ridotto alle ultime 4 righe (il filo a scomparsa è il passo 6).
- `AGENTS.md`: la regola «No telemetry, ever» guadagna l'eccezione «CALL suggestions: on the user's initiative, off by default, kill-switch in the CALL view; they send the call transcript to Claude via the local `claude` CLI».

- [ ] **Step 1: Implement** la vista e i testi.
- [ ] **Step 2: Build + test** — `make test 2>&1 | tail -3 && make app 2>&1 | tail -1` → Expected: test verdi, `Built …`.
- [ ] **Step 3: Verify on screen** — fantasmino spento (`screenPrivacy false`) per poter catturare; `callTranscribeFile` su `q20.aiff`; screenshot della notch espansa con domanda, suggerimento e barra; screenshot con interruttore spento. Confronto con il mockup 2a in `docs/superpowers/specs/2026-11-16-call-mode-mockups.html`.
- [ ] **Step 4: Commit** — `feat(call): suggestion card, consent switch and client folder in the notch` (+ audit e AGENTS.md nello stesso commit o in un `docs:` separato).
- [ ] **Step 5: Real call (con Matteo)** — Meet in cuffia, lid aperto, interruttore acceso, 5 domande vere: aperte, chiuse, una ripetuta, una mentre Matteo parla. Esito nell'audit.
