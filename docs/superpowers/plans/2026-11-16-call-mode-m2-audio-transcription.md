# CALL mode M2 — cattura audio e trascrizione live Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** In CALL, «Inizia ad ascoltare» cattura su due canali separati l'audio della riunione (il cliente) e il microfono (Matteo), li trascrive in italiano in locale e mostra le ultime battute nella notch; il trascritto vive solo in RAM.

**Architecture:** Il modello del trascritto e le decisioni pure (quale processo è la riunione, se l'uscita è in cuffia, che messaggio mostrare quando manca un permesso) stanno in `VedettaKit` con test. In `Vedetta`: un process tap Core Audio sulla riunione, un tap su `AVAudioEngine.inputNode` per il microfono, due `SpeechAnalyzer` (uno per canale) con `SpeechTranscriber` it-IT, e un `CallSession` che li orchestra e pubblica il trascritto alla UI. Questo milestone risponde anche alla domanda aperta dello spec: `SpeechTranscriber` mette il punto interrogativo in italiano?

**Tech Stack:** Swift 6, Core Audio process tap (`CATapDescription`, `AudioHardwareCreateProcessTap`), AVFAudio, Speech (`SpeechAnalyzer`, `SpeechTranscriber`, `AssetInventory`), SwiftUI, Swift Testing.

**Spec:** `docs/superpowers/specs/2026-11-16-call-mode-copilot-design.md` (ordine di costruzione, passo 1) e `docs/superpowers/specs/2026-09-02-call-mode-design.md` (audio, trascrizione, cuffie, permessi).

## Global Constraints

- Il pacchetto resta `.macOS(.v14)` e `LSMinimumSystemVersion` 14.0: tutto il codice Speech sta dietro `@available(macOS 26, *)` / `if #available(macOS 26, *)`. Su macOS < 26 il pulsante «Inizia ad ascoltare» è disabilitato con la scritta «Richiede macOS 26».
- **Non usare `AnalyzerInputConverter`**: è `anyAppleOS 27`. Conversione di formato con `AVAudioConverter` verso `SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith:)`.
- Locale: `Locale(identifier: "it-IT")`. Asset al primo uso: `AssetInventory.assetInstallationRequest(supporting:)` → `downloadAndInstall()`, con progresso visibile.
- Audio di sistema: **process tap Core Audio** sul processo della riunione, non ScreenCaptureKit (spec 09-02, «Privacy, permessi»). Il prompt TCC compare ad `AudioDeviceStart`: si avvia solo su «Inizia ad ascoltare», mai al lancio.
- Info.plist (generato in `Scripts/make-app.sh`): aggiungere `NSMicrophoneUsageDescription` = «Meowtch listens to your microphone during a call to know when you are speaking.» e `NSAudioCaptureUsageDescription` = «Meowtch listens to the meeting audio during a call to transcribe what the other side says, on this Mac.»
- **Il trascritto non tocca il disco** in questo milestone (la registrazione è il passo 5 dello spec). Nessun audio salvato, mai.
- Nessuna dipendenza nuova. Nessun traffico di rete (tranne il download dell'asset di sistema, gestito da macOS).
- Test solo in `VedettaKit` (`App/Tests/VedettaKitTests/`, `import Testing`, `@Test`, `#expect`). AppKit/audio in `Vedetta` con verifica manuale reale.
- Build dalla root: `make test`, `make app` (scelgono Xcode da soli). Firma stabile «Vedetta Dev Signing» già gestita da `make app`.
- Testi visibili in inglese come il resto dell'app; registro impersonale (mai «I'm listening»: «Listening»).
- Naming: Meowtch per l'utente, Vedetta all'interno. Riferimento per la sequenza di chiamate del process tap: `insidegui/AudioCap` (leggerlo, non copiarlo: Meowtch è MIT).
- Niente è fatto senza prova reale: audio vero da Meet o da un video nel browser, in cuffia.

## Review Focus

1. **Meet in Chrome suona da un processo helper**, non dal processo principale: il resolver deve riconoscere `com.google.Chrome.helper` e simili, altrimenti il canale cliente resta muto. → test in Task 2.
2. **Permesso negato** (microfono o audio di sistema): messaggio esplicito nella notch con il percorso in Impostazioni di Sistema, mai silenzio. → test in Task 2, verifica in Task 5.
3. **Risultati volatili che diventano finali**: aggiornamenti successivi dello stesso tratto non devono duplicare righe. → test in Task 1.
4. **Uscita da CALL o Stop a metà**: tap, aggregate device e motore audio rilasciati; il pallino arancione del microfono di macOS si spegne. → verifica in Task 5.
5. **Asset it-IT assente**: progresso del download visibile, ascolto che parte da solo a download finito, nessun blocco silenzioso. → verifica in Task 4.

---

## File Structure

| File | Responsabilità |
|---|---|
| `App/Sources/VedettaKit/CallTranscript.swift` (nuovo) | Modello puro: battute per canale, volatili sostituite dai finali, ultime N righe. |
| `App/Sources/VedettaKit/CallAudioRules.swift` (nuovo) | Decisioni pure: processo della riunione, uscita in cuffia, messaggi per i problemi di ascolto. |
| `App/Tests/VedettaKitTests/CallTranscriptTests.swift`, `CallAudioRulesTests.swift` (nuovi) | Test dei due file sopra. |
| `App/Sources/Vedetta/Call/SystemAudioTap.swift` (nuovo) | Process tap + aggregate device → `AsyncStream<AVAudioPCMBuffer>`. |
| `App/Sources/Vedetta/Call/MicrophoneCapture.swift` (nuovo) | `AVAudioEngine` input tap → `AsyncStream<AVAudioPCMBuffer>`. |
| `App/Sources/Vedetta/Call/LiveTranscriber.swift` (nuovo, macOS 26) | Un `SpeechAnalyzer` per canale, conversione di formato, risultati → `CallTranscript.Update`. |
| `App/Sources/Vedetta/Call/CallSession.swift` (nuovo) | Orchestratore `@MainActor ObservableObject`: avvio/stop, stato, trascritto pubblicato. |
| `App/Sources/Vedetta/UI/CallListenView.swift` (nuovo) | Vista minima in CALL: pulsante, avvisi, ultime battute. |
| `App/Sources/Vedetta/UI/NotchView.swift` (modifica) | In CALL mostra `CallListenView` al posto della lista sessioni. |
| `App/Sources/Vedetta/EventDispatcher.swift` (modifica) | Comandi debug `callListen`, `callTranscript`. |
| `Scripts/make-app.sh` (modifica) | Le due chiavi di Info.plist. |
| `docs/vi-binary-audit.md` (modifica, Task 6) | Esito della prova sulla punteggiatura e sulle latenze. |

---

### Task 1: Modello del trascritto

**Files:**
- Create: `App/Sources/VedettaKit/CallTranscript.swift`
- Test: `App/Tests/VedettaKitTests/CallTranscriptTests.swift`

**Interfaces:**
- Produces:
  - `public enum CallSpeaker: String, Sendable { case client, me }`
  - `public struct CallLine: Equatable, Sendable, Identifiable { public let id: UUID; public let speaker: CallSpeaker; public var text: String; public var isFinal: Bool; public let startedAt: Date; public var updatedAt: Date }`
  - `public struct CallTranscript: Sendable { public init(); public private(set) var lines: [CallLine]; public mutating func apply(_ update: Update); public func recent(_ limit: Int) -> [CallLine]; public var liveLine: CallLine? }`
  - `public struct CallTranscript.Update: Sendable { speaker: CallSpeaker; text: String; isFinal: Bool; at: Date }`

Regola: per ogni canale esiste al massimo una riga **non finale**, sempre l'ultima di quel canale. Un update volatile la sostituisce (o la crea); un update finale la chiude (`isFinal = true`) e il prossimo update di quel canale apre una riga nuova. Testo vuoto o solo spazi: ignorato. `liveLine` = la riga non finale più recente fra i due canali.

- [ ] **Step 1: Write the failing tests**

```swift
@Test func volatileUpdatesReplaceTheOpenLine() {
    var t = CallTranscript()
    t.apply(.init(speaker: .client, text: "Ma il carrello", isFinal: false, at: t0))
    t.apply(.init(speaker: .client, text: "Ma il carrello misto", isFinal: false, at: t0 + 1))
    #expect(t.lines.count == 1)
    #expect(t.lines[0].text == "Ma il carrello misto")
    #expect(t.liveLine?.text == "Ma il carrello misto")
}
@Test func finalClosesTheLineAndNextUpdateOpensANewOne() {
    // final "…funziona già?" then volatile "e poi" → 2 lines, first isFinal, second not
}
@Test func channelsKeepSeparateOpenLines() {
    // client volatile, me volatile, client final → client line final, me line still open; 2 lines total
}
@Test func blankUpdatesAreIgnored() { /* "  " volatile → lines.isEmpty */ }
@Test func recentReturnsTheLastLinesInOrder() { /* 5 finals, recent(3) → last 3, oldest first */ }
```

- [ ] **Step 2: Run to verify they fail** — `make test` → errore di compilazione «cannot find 'CallTranscript'».
- [ ] **Step 3: Implement `CallTranscript`** in `CallTranscript.swift` secondo la regola sopra.
- [ ] **Step 4: Run** — `make test` → tutti verdi.
- [ ] **Step 5: Commit** — `git commit -m "feat(call): transcript model with per-channel live lines"`

---

### Task 2: Regole audio pure

**Files:**
- Create: `App/Sources/VedettaKit/CallAudioRules.swift`
- Test: `App/Tests/VedettaKitTests/CallAudioRulesTests.swift`

**Interfaces:**
- Produces:
  - `public struct AudioProcessInfo: Sendable, Equatable { public let objectID: UInt32; public let pid: Int32; public let bundleID: String?; public let isRunningOutput: Bool }`
  - `public enum CallAudioRules { public static func meetingProcesses(_ all: [AudioProcessInfo], excludingPID own: Int32) -> [UInt32]; public static func isHeadphoneOutput(transportType: UInt32, dataSource: UInt32?) -> Bool }`
  - `public enum CallListenProblem: Equatable, Sendable { case requiresMacOS26, microphoneDenied, systemAudioDenied, noMeetingAudio, speechAssetDownloading(fraction: Double), speechUnavailable; public var message: String }`

Regole:
- **Riunione:** bundle ID che iniziano con uno di `com.google.Chrome`, `com.apple.Safari`, `com.apple.WebKit`, `company.thebrowser.Browser`, `com.brave.Browser`, `com.microsoft.edgemac`, `org.mozilla.firefox`, `us.zoom.xos`, `com.microsoft.teams2`, `com.apple.FaceTime`. Fra questi, se qualcuno ha `isRunningOutput`, solo quelli; altrimenti tutti i corrispondenti. Il proprio PID è sempre escluso. Nessuna corrispondenza → `[]` (il chiamante userà un tap globale che esclude Meowtch).
- **Cuffia:** `transportType` Bluetooth (`'blue'`) o BluetoothLE (`'blea'`) o USB (`'usb '`) → true; built-in (`'bltn'`) → true solo se `dataSource == 'hdpn'`; tutto il resto false.
- **Messaggi** (copy esatta):
  - `requiresMacOS26` → "Listening requires macOS 26."
  - `microphoneDenied` → "Microphone access is off. System Settings › Privacy & Security › Microphone › Meowtch."
  - `systemAudioDenied` → "Meeting audio access is off. System Settings › Privacy & Security › Screen & System Audio Recording › System Audio Recording Only › Meowtch."
  - `noMeetingAudio` → "No meeting audio found. Start the call first, then listen."
  - `speechAssetDownloading(f)` → "Downloading Italian speech model… \(Int(f*100))%"
  - `speechUnavailable` → "Italian transcription is not available on this Mac."

- [ ] **Step 1: Write the failing tests**

```swift
@Test func chromeHelperIsTheMeeting() {
    let all = [p(1, "com.google.Chrome", out: false), p(2, "com.google.Chrome.helper", out: true), p(3, "com.spotify.client", out: true)]
    #expect(CallAudioRules.meetingProcesses(all, excludingPID: 99) == [2])
}
@Test func withNoActiveOutputAllMatchingProcessesAreTapped() { /* Chrome + helper, none running → [1, 2] */ }
@Test func ownProcessIsNeverTapped() { /* entry with pid == own excluded even if Chrome-like */ }
@Test func unknownAppsOnlyMeansGlobalFallback() { /* only Spotify → [] */ }
@Test func headphoneDetection() {
    #expect(CallAudioRules.isHeadphoneOutput(transportType: fourCC("blue"), dataSource: nil))
    #expect(CallAudioRules.isHeadphoneOutput(transportType: fourCC("bltn"), dataSource: fourCC("hdpn")))
    #expect(!CallAudioRules.isHeadphoneOutput(transportType: fourCC("bltn"), dataSource: fourCC("ispk")))
}
@Test func permissionMessagesNameTheSettingsPath() {
    #expect(CallListenProblem.microphoneDenied.message.contains("Privacy & Security › Microphone"))
    #expect(CallListenProblem.speechAssetDownloading(fraction: 0.42).message.hasSuffix("42%"))
}
```

(`fourCC` = helper di test che converte 4 caratteri in `UInt32` big-endian.)

- [ ] **Step 2: Run to verify they fail** — `make test` → «cannot find 'CallAudioRules'».
- [ ] **Step 3: Implement** `CallAudioRules` e `CallListenProblem` con i valori sopra.
- [ ] **Step 4: Run** — `make test` → verdi.
- [ ] **Step 5: Commit** — `git commit -m "feat(call): pure rules for meeting process, headphones, listen problems"`

---

### Task 3: Cattura audio a due canali

**Files:**
- Create: `App/Sources/Vedetta/Call/SystemAudioTap.swift`, `App/Sources/Vedetta/Call/MicrophoneCapture.swift`
- Modify: `Scripts/make-app.sh` (Info.plist), `App/Sources/Vedetta/EventDispatcher.swift` (debug `callListen`, solo livelli in questo task)

**Interfaces:**
- Consumes: `CallAudioRules.meetingProcesses`, `CallListenProblem` (Task 2).
- Produces:
  - `final class SystemAudioTap { init(); func start() throws -> AsyncStream<AVAudioPCMBuffer>; func stop(); var format: AVAudioFormat? { get } }` — enumera i processi (`kAudioHardwarePropertyProcessObjectList`, `kAudioProcessPropertyPID`, `…BundleID`, `…IsRunningOutput`), sceglie con `meetingProcesses`; con `[]` usa `CATapDescription(stereoGlobalTapButExcludeProcesses:)` sul proprio processo. Tap privato e muteBehavior `.unmuted`; aggregate device privato con il tap; IOProc a blocchi che copia in `AVAudioPCMBuffer`. Errori di avvio mappati a `CallListenProblem.systemAudioDenied` (`kAudioHardwareIllegalOperationError` / `'!pri'` all'`AudioDeviceStart`).
  - `final class MicrophoneCapture { func start() throws -> AsyncStream<AVAudioPCMBuffer>; func stop() }` — `AVCaptureDevice.requestAccess(for: .audio)` prima; negato → `CallListenProblem.microphoneDenied`.
  - Debug socket: `{"cmd":"callListen","value":true|false}` avvia/ferma solo la cattura e risponde `{"listening":Bool,"clientRMS":Double,"meRMS":Double}` (RMS dell'ultimo buffer per canale).

- [ ] **Step 1: Info.plist** — aggiungere le due chiavi con la copy dei Global Constraints in `Scripts/make-app.sh`; `make app`; verifica: `plutil -p dist/Meowtch.app/Contents/Info.plist | grep UsageDescription` mostra entrambe.
- [ ] **Step 2: Implement `MicrophoneCapture`** come da interfaccia.
- [ ] **Step 3: Implement `SystemAudioTap`** come da interfaccia; `stop()` distrugge IOProc, aggregate device e tap in quest'ordine.
- [ ] **Step 4: Debug command `callListen`** in `EventDispatcher.handleCommand`, accanto a `callMode`.
- [ ] **Step 5: Verifica reale** — in cuffia, video YouTube in Chrome a volume normale, `make app`, rilancio, `callListen true`: accettare i due prompt; 5 interrogazioni a 1 s: `clientRMS > 0.01` col video in riproduzione, ~0 in pausa; `meRMS > 0.01` parlando. Poi `callListen false`: il pallino arancione del microfono nella barra dei menu sparisce entro 2 s.
- [ ] **Step 6: Commit** — `git commit -m "feat(call): capture meeting audio via process tap and the microphone"`

---

### Task 4: Trascrizione live per canale

**Files:**
- Create: `App/Sources/Vedetta/Call/LiveTranscriber.swift`
- Modify: `App/Sources/Vedetta/EventDispatcher.swift` (debug `callTranscript`)

**Interfaces:**
- Consumes: `CallTranscript.Update`, `CallSpeaker` (Task 1); `CallListenProblem` (Task 2); gli stream di Task 3.
- Produces:
  - `@available(macOS 26, *) final class LiveTranscriber { init(speaker: CallSpeaker, locale: Locale = Locale(identifier: "it-IT")); static func prepareAssets(progress: @escaping @Sendable (Double) -> Void) async throws; func run(_ audio: AsyncStream<AVAudioPCMBuffer>, onUpdate: @escaping @Sendable (CallTranscript.Update) -> Void) async throws; func stop() async }`
  - `SpeechTranscriber(locale:transcriptionOptions: [], reportingOptions: [.volatileResults], attributeOptions: [])`; `SpeechAnalyzer(modules: [transcriber])`; input `AsyncStream<AnalyzerInput>` alimentato convertendo ogni buffer con `AVAudioConverter` verso `SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber])`. Ogni `result` → `Update(speaker, text: String(result.text.characters), isFinal: result.isFinal, at: Date())`.
  - `prepareAssets`: se `SpeechTranscriber.supportedLocales` non contiene it-IT → `CallListenProblem.speechUnavailable`; altrimenti `AssetInventory.assetInstallationRequest(supporting:)`, se non nil `downloadAndInstall()` riportando `request.progress.fractionCompleted`.
  - Debug socket: `{"cmd":"callTranscript"}` → `{"lines":[{"speaker":"client","text":"…","final":true}, …]}` (ultime 20).

- [ ] **Step 1: Implement `LiveTranscriber`** come da interfaccia.
- [ ] **Step 2: Debug command `callTranscript`.**
- [ ] **Step 3: Verifica reale, asset** — se l'asset it-IT è già installato, annotarlo; altrimenti `callListen true` deve mostrare il progresso (via `callListen` risposta o log) e partire da solo a fine download.
- [ ] **Step 4: Verifica reale, trascrizione** — video in italiano nel browser + frasi dette al microfono: `callTranscript` mostra righe `client` col parlato del video e righe `me` con le proprie frasi, nessuna riga duplicata, finali che arrivano entro qualche secondo dalla pausa.
- [ ] **Step 5: Commit** — `git commit -m "feat(call): live Italian transcription per channel with SpeechAnalyzer"`

---

### Task 5: Sessione di ascolto e vista minima in CALL

**Files:**
- Create: `App/Sources/Vedetta/Call/CallSession.swift`, `App/Sources/Vedetta/UI/CallListenView.swift`
- Modify: `App/Sources/Vedetta/UI/NotchView.swift`, `App/Sources/Vedetta/EventDispatcher.swift` (`callListen` passa da `CallSession`)

**Interfaces:**
- Consumes: Task 1–4.
- Produces:
  - `@MainActor final class CallSession: ObservableObject { static let shared; @Published private(set) var isListening: Bool; @Published private(set) var transcript: CallTranscript; @Published private(set) var problem: CallListenProblem?; @Published private(set) var headphones: Bool; func start(); func stop() }`
  - `start()`: macOS < 26 → `problem = .requiresMacOS26`; poi asset, poi cattura, poi due `LiveTranscriber` in task separati. `stop()`: ferma trascrittori, cattura, svuota il trascritto (RAM soltanto).
  - Si ferma da solo quando `ScreenPrivacy.shared.mode` passa a `.code`.
  - `CallListenView`: con `mode == .call` sostituisce la lista sessioni. Contiene: pulsante «Start listening» / «Stop»; riga di avviso arancione se `!headphones` («Not on headphones: the meeting can leak into the microphone.»); `problem?.message` in rosso; le ultime 6 righe di `transcript.recent(6)` con etichetta «Client» (blu) / «You» (verde), la `liveLine` in corsivo. Stile coerente con i mockup 2c.

- [ ] **Step 1: Implement `CallSession`.**
- [ ] **Step 2: Implement `CallListenView`** e collegarla in `NotchView`.
- [ ] **Step 3: Verifica reale** — screenshot della notch espansa in CALL (fantasmino spento per poterla catturare) durante un video italiano in cuffia: righe Client/You che compaiono e si consolidano.
- [ ] **Step 4: Verifica dei casi limite** — (a) negare il microfono in Impostazioni → messaggio esatto in notch; (b) speaker del Mac → avviso cuffie; (c) Stop e poi passaggio a CODE → pallino arancione del microfono spento, `callTranscript` vuoto.
- [ ] **Step 5: Commit** — `git commit -m "feat(call): listening session and live transcript in the notch"`

---

### Task 6: Prova su audio reale — punteggiatura e latenze

**Files:**
- Modify: `docs/vi-binary-audit.md` (progress log), `docs/superpowers/specs/2026-09-02-call-mode-design.md` (riga di rischio sulla punteggiatura)

- [ ] **Step 1: Campione** — 20 domande reali in italiano (10 dal video/call, 10 dette al microfono), metà con marcatore lessicale («quando», «come», «riuscite»), metà chiuse senza marcatore («Il carrello funziona già»).
- [ ] **Step 2: Misure** da `callTranscript`: quante righe finali finiscono con «?» per gruppo; ritardo medio fra la fine del parlato (a orecchio, cronometro) e l'arrivo della riga finale.
- [ ] **Step 3: Scrivere l'esito** nel progress log dell'audit e aggiornare la riga di rischio nello spec 09-02: «verificato» con i numeri, oppure «la punteggiatura non basta → il trigger del passo successivo usa marcatori lessicali + modello piccolo».
- [ ] **Step 4: Commit** — `git commit -m "docs(call): Italian question punctuation and latency, measured"`
