# CALL mode M1 — protezione dalla cattura schermo Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Un toggle CODE ⇄ CALL nella notch che tiene ogni finestra di Meowtch fuori dalle condivisioni schermo, chiudendo una fuga di privacy che esiste oggi.

**Architecture:** Un enum puro in `VedettaKit` decide *se* nascondersi; una singola classe in `Vedetta` applica `sharingType` a ogni finestra — sia quelle che si registrano alla creazione, sia con una spazzata su `NSApp.windows` a ogni cambio di modalità e a ogni finestra che diventa key. La modalità **non** viene persistita fra i lanci: una modalità che nasconde l'interfaccia non va mai ripristinata in silenzio.

**Tech Stack:** Swift 6, AppKit (`NSWindow.sharingType`), SwiftUI, Swift Testing.

**Spec:** `docs/superpowers/specs/2026-09-02-call-mode-design.md`

## Global Constraints

- **macOS 26** è il target; nessuna dipendenza nuova.
- `sharingType` è **per-finestra**: una sola superficie dimenticata vanifica la feature (spec, §1 delle evidenze).
- I test girano **solo per `VedettaKit`** (`App/Tests/VedettaKitTests/`). Logica pura lì, AppKit in `Vedetta` con verifica manuale.
- Naming: *Meowtch* è ciò che vede l'utente, *Vedetta* resta ovunque internamente. Non "correggere" mai un riferimento Vedetta interno.
- Build dalla **root del repo**: `make test`, `make app`. Mai da `App/`.
- Framework di test: `import Testing`, `@Test`, `#expect` — non XCTest.
- **Niente è "fatto" finché non è esercitato con una cattura reale**, non con una build verde (regola del repo).
- Firma: l'identità stabile *"Vedetta Dev Signing"* tiene vivi i grant TCC fra le ricompilazioni; `make app` la usa già.

---

## File Structure

| File | Responsabilità |
|---|---|
| `App/Sources/VedettaKit/CallMode.swift` **(nuovo)** | L'enum puro e la decisione «questa modalità si nasconde?». Nessun AppKit: è la parte testabile. |
| `App/Tests/VedettaKitTests/CallModeTests.swift` **(nuovo)** | Test dell'enum. |
| `App/Sources/Vedetta/ScreenPrivacy.swift` **(nuovo)** | Il punto unico che applica `sharingType`. `ObservableObject`, così la UI ci si aggancia senza stato duplicato. |
| `App/Sources/Vedetta/NotchPanel.swift` **(modifica)** | Si registra alla creazione. |
| `App/Sources/Vedetta/OnboardingController.swift:29` **(modifica)** | Idem. |
| `App/Sources/Vedetta/Settings/SettingsWindowController.swift:27` **(modifica)** | Idem. |
| `App/Sources/Vedetta/UI/NotchView.swift` **(modifica)** | Il toggle nella `topBar`, a sinistra dello speaker. |

Nessuna modifica a `SettingsDefaults.swift`: la modalità non si persiste, quindi non è una preferenza.

---

### Task 1: `CallMode` — l'enum puro

**Files:**
- Create: `App/Sources/VedettaKit/CallMode.swift`
- Test: `App/Tests/VedettaKitTests/CallModeTests.swift`

**Interfaces:**
- Consumes: niente.
- Produces: `public enum CallMode: String, CaseIterable, Sendable { case code, call }` e `public var hidesFromScreenCapture: Bool`.

> Nota di revisione: una prima stesura prevedeva anche `mode(rawValue:)` per decodificare
> un valore persistito. È stata rimossa: la modalità **non** si persiste, quindi quel
> decoder non sarebbe stato chiamato da nessuno. I raw value restano stabili perché
> serviranno a M4 (comando di debug sul socket), e c'è un test che li blocca.

- [ ] **Step 1: Write the failing test**

Crea `App/Tests/VedettaKitTests/CallModeTests.swift`:

```swift
import Testing
@testable import VedettaKit

struct CallModeTests {
    @Test func rawValuesAreStable() {
        // Frozen on purpose: M4 exposes the mode over the debug socket, and a
        // renamed case there would break the wire format silently.
        #expect(CallMode.code.rawValue == "code")
        #expect(CallMode.call.rawValue == "call")
        #expect(CallMode.allCases.count == 2)
    }

    @Test func onlyCallHidesFromScreenCapture() {
        #expect(CallMode.code.hidesFromScreenCapture == false)
        #expect(CallMode.call.hidesFromScreenCapture == true)
    }
}
```

- [ ] **Step 2: Run the test and watch it fail**

```bash
make test
```

Atteso: fallimento in compilazione, `cannot find 'CallMode' in scope`.

- [ ] **Step 3: Write the minimal implementation**

Crea `App/Sources/VedettaKit/CallMode.swift`:

```swift
import Foundation

/// What the notch currently is. CODE is the agent-session panel Meowtch has
/// always been; CALL turns it into the in-call copilot and keeps every window
/// out of screen shares.
public enum CallMode: String, CaseIterable, Sendable {
    case code
    case call

    /// Only CALL asks AppKit to keep the window out of screen captures.
    public var hidesFromScreenCapture: Bool { self == .call }
}
```

- [ ] **Step 4: Run the test and watch it pass**

```bash
make test
```

Atteso: PASS, due test in `CallModeTests`.

- [ ] **Step 5: Commit**

```bash
git add App/Sources/VedettaKit/CallMode.swift App/Tests/VedettaKitTests/CallModeTests.swift
git commit -m "feat: CallMode decides whether the notch hides from capture"
```

---

### Task 2: `ScreenPrivacy` — il punto unico che applica il flag

**Files:**
- Create: `App/Sources/Vedetta/ScreenPrivacy.swift`
- Modify: `App/Sources/Vedetta/NotchPanel.swift` (in fondo a `init`)
- Modify: `App/Sources/Vedetta/OnboardingController.swift:29` (dopo la creazione della finestra)
- Modify: `App/Sources/Vedetta/Settings/SettingsWindowController.swift:27` (idem)

**Interfaces:**
- Consumes: `CallMode` da Task 1.
- Produces: `@MainActor final class ScreenPrivacy: ObservableObject` con `static let shared`, `@Published private(set) var mode: CallMode`, `func setMode(_ mode: CallMode)`, `func register(_ window: NSWindow)`. La spazzata su tutte le finestre è un dettaglio interno e resta `private`.

Nessun test unitario: `NSWindow` è AppKit e il target `Vedetta` non ha suite. La verifica è il Task 4, con una cattura reale.

- [ ] **Step 1: Write `ScreenPrivacy`**

Crea `App/Sources/Vedetta/ScreenPrivacy.swift`:

```swift
import AppKit
import VedettaKit

/// The single place that decides whether Meowtch's windows appear in screen
/// captures. `sharingType` is a per-window flag, so one forgotten surface
/// defeats the whole feature: windows register themselves at creation, and
/// every mode change re-sweeps whatever AppKit already owns.
///
/// The mode is deliberately NOT persisted across launches. A mode that hides
/// the app's own interface must never come back silently after a restart.
@MainActor
final class ScreenPrivacy: ObservableObject {
    static let shared = ScreenPrivacy()

    @Published private(set) var mode: CallMode = .code

    private var keyWindowObserver: NSObjectProtocol?

    private init() {
        // Windows AppKit creates on its own — alerts, save panels — never call
        // register(). Catching them as they become key is the safety net.
        keyWindowObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeKeyNotification, object: nil, queue: .main
        ) { note in
            // Deliberately captures nothing: touching `self` from a closure
            // built inside init is a needless compile-time hazard, and the
            // closure only ever runs long after `shared` exists.
            let window = note.object as? NSWindow
            Task { @MainActor in
                guard let window else { return }
                ScreenPrivacy.shared.register(window)
            }
        }
    }

    func setMode(_ mode: CallMode) {
        guard mode != self.mode else { return }
        self.mode = mode
        applyToAllWindows()
    }

    /// Call from a window's init. Idempotent.
    func register(_ window: NSWindow) {
        apply(to: window)
    }

    private func applyToAllWindows() {
        for window in NSApp.windows { apply(to: window) }
    }

    private func apply(to window: NSWindow) {
        // .readOnly is AppKit's default: capture allowed, no remote control.
        window.sharingType = mode.hidesFromScreenCapture ? .none : .readOnly
    }
}
```

- [ ] **Step 2: Register the notch panel**

In `App/Sources/Vedetta/NotchPanel.swift`, come ultima riga di `init(contentRect:)`, subito dopo `animationBehavior = .utilityWindow`:

```swift
        ScreenPrivacy.shared.register(self)
```

- [ ] **Step 3: Register the onboarding window**

In `App/Sources/Vedetta/OnboardingController.swift`, subito dopo che la `NSWindow` creata alla riga 29 è stata configurata (prima che venga mostrata), aggiungi:

```swift
        ScreenPrivacy.shared.register(window)
```

- [ ] **Step 4: Register the settings window**

In `App/Sources/Vedetta/Settings/SettingsWindowController.swift`, subito dopo la creazione della `NSWindow` alla riga 27:

```swift
            ScreenPrivacy.shared.register(window)
```

- [ ] **Step 5: Build and confirm nothing regressed**

```bash
make test && make app
```

Atteso: test verdi, build riuscita. Il comportamento a runtime non cambia ancora: senza toggle, la modalità resta `.code` e `sharingType` viene impostato al valore che AppKit usa già.

- [ ] **Step 6: Commit**

```bash
git add App/Sources/Vedetta/ScreenPrivacy.swift App/Sources/Vedetta/NotchPanel.swift App/Sources/Vedetta/OnboardingController.swift App/Sources/Vedetta/Settings/SettingsWindowController.swift
git commit -m "feat: one place applies sharingType to every Meowtch window"
```

---

### Task 3: Il toggle CODE ⇄ CALL, e come si vede che è attivo

**Files:**
- Modify: `App/Sources/Vedetta/UI/NotchView.swift` (la `topBar`, oggi intorno alla riga 398)

**Interfaces:**
- Consumes: `ScreenPrivacy.shared` e `CallMode` dai Task 1-2.
- Produces: nessuna API nuova.

- [ ] **Step 1: Observe `ScreenPrivacy` in the view**

`NotchView.swift` importa già `AppKit`, `SwiftUI` e `VedettaKit` (verificato): non serve toccare gli import.

Accanto a `@State private var muted = SoundEngine.shared.isMuted` (oggi riga 398), aggiungi:

```swift
    @ObservedObject private var privacy = ScreenPrivacy.shared
```

- [ ] **Step 2: Insert the toggle to the left of the speaker button**

Nella `topBar`, fra `Spacer()` e il `Button` dello speaker, inserisci:

```swift
            Button {
                privacy.setMode(privacy.mode == .call ? .code : .call)
            } label: {
                HStack(spacing: 3) {
                    Image(systemName: privacy.mode == .call
                          ? "phone.fill"
                          : "chevron.left.forwardslash.chevron.right")
                    Text(privacy.mode == .call ? "CALL" : "CODE")
                        .font(.system(size: 9, weight: .bold))
                }
                // Fixed width so the speaker and gear never shift when the
                // label changes length — the same trick the mute icon uses.
                .frame(width: 54, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(PressFlashStyle())
            .help(privacy.mode == .call
                  ? "CALL — Meowtch stays out of screen shares"
                  : "CODE — Meowtch appears in screen shares")
```

- [ ] **Step 3: Show the mode when the notch is collapsed**

Senza questo passo si entra in CALL, si collassa la notch, e non resta **alcun** modo
di sapere di essere invisibili: gli screenshot successivi mancherebbero pezzi senza
spiegazione. La spec lo chiede esplicitamente («in CALL, notch collassata: un
indicatore minimo»).

In `collapsedContent` (oggi riga 153), fra `Spacer()` e il blocco
`if !visibleSessions.isEmpty`, inserisci:

```swift
            if privacy.mode == .call {
                Image(systemName: "phone.fill")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(Theme.secondaryText)
            }
```

`privacy` è già osservato dalla stessa `NotchView` (Step 1), quindi non serve altro.

- [ ] **Step 4: Build**

```bash
make test && make app
```

Atteso: test verdi, build riuscita.

- [ ] **Step 5: Commit**

```bash
git add App/Sources/Vedetta/UI/NotchView.swift
git commit -m "feat: CODE/CALL toggle, visible expanded and collapsed"
```

---

### Task 4: Verifica end-to-end con una cattura reale

**Files:** nessuno. Questo task esiste perché la regola del repo dice che una build verde non è una verifica, e perché il Task 2 non ha test unitari.

**Interfaces:** nessuna.

- [ ] **Step 1: Launch the built app**

Se una copia di Meowtch è già in esecuzione, **chiudila dalla sua voce di menu**
("Quit Meowtch" nel menu della status bar). Non usare `pkill` per nome: in questo
progetto un `pkill` per nome di processo ha già ucciso sessioni non correlate.

```bash
open dist/Meowtch.app
```

Espandi la notch e verifica a occhio che il toggle mostri **CODE**.

- [ ] **Step 2: Capture in CODE — the notch must be there**

Con la notch espansa:

```bash
screencapture -x /tmp/meowtch-code.png && open /tmp/meowtch-code.png
```

Atteso: il pannello della notch **è visibile** nell'immagine. Se non lo è, il test
successivo non prova nulla — fermati e capisci perché.

⚠️ Con più display collegati `screencapture` può scrivere un file per schermo
(`meowtch-code.png`, `meowtch-code 2.png`). Guarda quello del **display del MacBook**:
è lì che vive la notch. Vale per tutte le catture di questo task.

- [ ] **Step 3: Switch to CALL and capture again**

Clicca il toggle (deve mostrare **CALL**), poi:

```bash
screencapture -x /tmp/meowtch-call.png && open /tmp/meowtch-call.png
```

Atteso: il pannello della notch è **assente** dall'immagine, mentre tutto il resto dello schermo c'è.

- [ ] **Step 4: Verify the Settings window is protected too**

Restando in CALL, apri Settings dalla notch, poi:

```bash
screencapture -x /tmp/meowtch-call-settings.png && open /tmp/meowtch-call-settings.png
```

Atteso: **anche la finestra Settings è assente**. È il test che dimostra che la registrazione non copre solo la notch — il punto in cui la feature fallisce più facilmente.

- [ ] **Step 5: Confirm the collapsed indicator**

Restando in CALL, lascia collassare la notch. Atteso: compare il glifo del telefono
accanto al contatore delle sessioni. È l'unico segnale che hai di essere invisibile
quando il pannello è chiuso.

- [ ] **Step 6: Switch back to CODE and confirm it returns**

```bash
screencapture -x /tmp/meowtch-back-to-code.png && open /tmp/meowtch-back-to-code.png
```

Atteso: notch e Settings **tornano visibili**. Una protezione che non si spegne è un bug quanto una che non si accende: senza questo passo, screenshot per la documentazione e registrazioni Loom resterebbero rotti.

- [ ] **Step 7: Verify against a real screen share**

Apri `https://webrtc.github.io/samples/src/content/getusermedia/getdisplaymedia/` in Chrome, premi **Start**, condividi **l'intero schermo del MacBook** e osserva l'anteprima mentre premi il toggle.

Atteso: la notch sparisce dall'anteprima passando a CALL e riappare tornando a CODE. È la stessa API che usa Google Meet, ed è l'unica verifica che conta davvero.

- [ ] **Step 8: Watch for AppKit side effects**

L'header di `NSWindow` avverte esplicitamente che una finestra con
`NSWindowSharingNone` *"will also not be able to participate in a number of system
services"*, senza dire quali. Restando in CALL, controlla che non si rompa nulla di
visibile: apri Mission Control e Stage Manager e verifica che la notch non lasci un
buco nero o un artefatto, e che tornando a CODE tutto sia normale.

Se emergesse un effetto collaterale, va annotato — non è un blocco per M1, ma è
esattamente il tipo di dettaglio che poi costa un pomeriggio.

- [ ] **Step 9: Record the verification in the audit**

`docs/vi-binary-audit.md` è la base di conoscenza viva del progetto: le scoperte
vanno lì, non in un commit vuoto. Aggiungi in fondo una voce con la data, cosa hai
catturato, l'esito nelle due modalità, l'esito contro `getDisplayMedia` di Chrome e
qualunque effetto collaterale emerso allo Step 8.

```bash
git add docs/vi-binary-audit.md
git commit -m "docs: record the CODE/CALL screen privacy verification"
```

---

## Cosa questo piano NON fa

M1 si ferma alla protezione e al toggle. In CALL la notch mostra ancora le
sessioni di coding — semplicemente, non finisce più nelle condivisioni. Tutto il
resto della spec resta da pianificare, e in quest'ordine:

| Milestone | Contenuto | Prerequisito |
|---|---|---|
| **M2** | Cattura audio dual-channel + trascrizione live + trascritto nella notch | **Spike sul process tap Core Audio** (`AudioHardwareCreateProcessTap`), e prova che `SpeechTranscriber` emetta punteggiatura interrogativa in italiano |
| **M3** | `TurnEndpointer`, `AnswerTrigger`, `ClaudeCLIEngine`, `ContextStore`, hotkey di override | M2 |
| **M4** | Terza sorgente per `UsageModel`, contatore live, budget, `OllamaEngine`, auto-switch | M3 |
| **M5** | Aggiornamento proposto della scheda cliente a fine call | M3 |

M2 non è pianificabile finché lo spike non dice se il process tap regge: pianificare
task TDD su un'API che potrebbe non funzionare significa scrivere finzione.
