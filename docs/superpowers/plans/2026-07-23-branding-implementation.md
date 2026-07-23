# Branding Vedetta — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Sostituire l'invader con la mascotte gattino (espressioni per stato + twitch), aggiornare gli indicatori (dual-chase running, squash compacting), rigenerare icona e DMG, aggiungere le GIF custom per stato — come da spec `docs/superpowers/specs/2026-07-23-branding-design.md`.

**Architecture:** La logica pura (pattern e selezione frame, cicli indicatori, risoluzione file GIF) vive in **VedettaKit** ed è unit-testata; le view SwiftUI (`MascotSprite`, `DualChaseSpinner`, `CompactingSquash`, `AnimatedImageView`) restano nell'app e leggono il clock condiviso `PixelClock`. Icona e DMG sono script Swift standalone in `scripts/`.

**Tech Stack:** Swift 6 / SwiftUI + AppKit, swift Testing (`import Testing`, `#expect`), CoreGraphics negli script, `hdiutil` + Finder AppleScript per il DMG.

## Global Constraints

- Build **dal root del repo**: `make app` (poi `open dist/Vedetta.app`); test: `make test` (TESTFLAGS workaround macOS 26 già nel Makefile).
- Commit **locali su `main`, MAI push**.
- Copy UI in inglese; commenti minimi nello stile del file ospite.
- Zero rete; asset originali (clean-room, nessun asset VI).
- Timing 8-bit: blink 1.2 s al 60% (`PixelClock.blinkOn`), spinner step 0.12 s, scansione occhi 0.36 s, squash 0.15 s.
- `SessionState` è `Int`-backed (`needsApproval=0 < running < compacting < waitingForInput < completed`): i filename GIF usano i **nomi dei case**, mai il rawValue.
- Niente "fatto" senza sessione live + conferma manuale di Matteo (Task 9).

---

### Task 1: MascotFrame (VedettaKit) — pattern e selezione frame

**Files:**
- Create: `App/Sources/VedettaKit/MascotFrame.swift`
- Test: `App/Tests/VedettaKitTests/MascotFrameTests.swift`
- Modify: `docs/superpowers/specs/2026-07-23-branding-design.md` (riga filename GIF: "col nome del case dello stato (`SessionState` è Int-backed)")

**Interfaces:**
- Consumes: `SessionState` (VedettaKit, esistente).
- Produces: `MascotFrame.base/lookLeft/lookRight/wideEyes/closedEyes/twitch: [String]`; `MascotFrame.frame(state:now:stateChangedAt:blinkOn:) -> [String]`; costanti `scanStep = 0.36`, `twitchWindow = 0.45`.

- [ ] **Step 1: Scrivi il test che fallisce**

```swift
import Foundation
import Testing
@testable import VedettaKit

struct MascotFrameTests {
    private let calm = Date.distantPast   // nessun twitch in corso

    @Test func patternsAreEightBySeven() {
        for pattern in [MascotFrame.base, MascotFrame.lookLeft, MascotFrame.lookRight,
                        MascotFrame.wideEyes, MascotFrame.closedEyes, MascotFrame.twitch] {
            #expect(pattern.count == 7)
            #expect(pattern.allSatisfy { $0.count == 8 })
        }
    }

    @Test func runningScansLeftCenterRight() {
        // tick k = now / 0.36; la sequenza è [base, sx, base, dx]
        let expected = [MascotFrame.base, MascotFrame.lookLeft,
                        MascotFrame.base, MascotFrame.lookRight]
        for k in 0..<4 {
            let now = Date(timeIntervalSinceReferenceDate: Double(k) * 0.36 + 0.01)
            let frame = MascotFrame.frame(state: .running, now: now,
                                          stateChangedAt: calm, blinkOn: true)
            #expect(frame == expected[k])
        }
    }

    @Test func compactingScansLikeRunning() {
        let now = Date(timeIntervalSinceReferenceDate: 0.37)
        let frame = MascotFrame.frame(state: .compacting, now: now,
                                      stateChangedAt: calm, blinkOn: true)
        #expect(frame == MascotFrame.lookLeft)
    }

    @Test func waitingBlinksBetweenOpenAndClosed() {
        let now = Date(timeIntervalSinceReferenceDate: 100)
        #expect(MascotFrame.frame(state: .waitingForInput, now: now,
                                  stateChangedAt: calm, blinkOn: true) == MascotFrame.base)
        #expect(MascotFrame.frame(state: .waitingForInput, now: now,
                                  stateChangedAt: calm, blinkOn: false) == MascotFrame.closedEyes)
    }

    @Test func approvalIsWideEyed() {
        let now = Date(timeIntervalSinceReferenceDate: 100)
        #expect(MascotFrame.frame(state: .needsApproval, now: now,
                                  stateChangedAt: calm, blinkOn: true) == MascotFrame.wideEyes)
    }

    @Test func completedSleeps() {
        let now = Date(timeIntervalSinceReferenceDate: 100)
        #expect(MascotFrame.frame(state: .completed, now: now,
                                  stateChangedAt: calm, blinkOn: true) == MascotFrame.closedEyes)
    }

    @Test func twitchBurstsTwiceAfterAStateChange() {
        let changed = Date(timeIntervalSinceReferenceDate: 100)
        func frame(after dt: TimeInterval) -> [String] {
            MascotFrame.frame(state: .running, now: changed.addingTimeInterval(dt),
                              stateChangedAt: changed, blinkOn: true)
        }
        #expect(frame(after: 0.05) == MascotFrame.twitch)    // primo burst
        #expect(frame(after: 0.20) != MascotFrame.twitch)    // pausa tra i burst
        #expect(frame(after: 0.35) == MascotFrame.twitch)    // secondo burst
        #expect(frame(after: 0.50) != MascotFrame.twitch)    // finestra chiusa
    }

    @Test func completedNeverTwitches() {
        let changed = Date(timeIntervalSinceReferenceDate: 100)
        let frame = MascotFrame.frame(state: .completed,
                                      now: changed.addingTimeInterval(0.05),
                                      stateChangedAt: changed, blinkOn: true)
        #expect(frame == MascotFrame.closedEyes)
    }
}
```

- [ ] **Step 2: Verifica che fallisca**

Run: `make test`
Expected: FAIL — "cannot find 'MascotFrame' in scope"

- [ ] **Step 3: Implementazione minima**

```swift
// App/Sources/VedettaKit/MascotFrame.swift
import Foundation

/// The guard-cat mascot: 8×7 pixel patterns and pure per-state frame
/// selection. Rendering stays in the app (PixelSprite); this type only
/// decides WHICH pattern is visible at a given instant. `o` marks an eye:
/// an unlit pixel, the renderer treats it like `.`.
public enum MascotFrame {
    public static let base: [String] = [
        ".#....#.",
        ".##..##.",
        ".######.",
        ".#o##o#.",
        ".######.",
        "..####..",
        "..#..#..",
    ]
    public static let lookLeft = row(base, 3, ".o##o##.")
    public static let lookRight = row(base, 3, ".##o##o.")
    public static let wideEyes = row(base, 4, ".#o##o#.")
    public static let closedEyes = row(row(base, 3, ".######."), 4, ".#o##o#.")
    public static let twitch = row(base, 0, "..#...#.")

    /// Eye-scan step for running/compacting.
    public static let scanStep: TimeInterval = 0.36
    /// The ear twitch plays two bursts inside this window after a state change.
    public static let twitchWindow: TimeInterval = 0.45

    public static func frame(
        state: SessionState,
        now: Date,
        stateChangedAt: Date,
        blinkOn: Bool
    ) -> [String] {
        let sinceChange = now.timeIntervalSince(stateChangedAt)
        if state != .completed, sinceChange >= 0, sinceChange < twitchWindow,
           sinceChange < 0.14 || (sinceChange > 0.28 && sinceChange < 0.42) {
            return twitch
        }
        switch state {
        case .running, .compacting:
            let tick = Int(now.timeIntervalSinceReferenceDate / scanStep)
            let seq = [base, lookLeft, base, lookRight]
            return seq[((tick % 4) + 4) % 4]
        case .waitingForInput:
            return blinkOn ? base : closedEyes
        case .needsApproval:
            return wideEyes
        case .completed:
            return closedEyes
        }
    }

    private static func row(_ pattern: [String], _ index: Int, _ line: String) -> [String] {
        var copy = pattern
        copy[index] = line
        return copy
    }
}
```

- [ ] **Step 4: Verifica che passi**

Run: `make test`
Expected: PASS (tutte le suite verdi, +8 test)

- [ ] **Step 5: Aggiorna la riga della spec sui filename GIF**

In `docs/superpowers/specs/2026-07-23-branding-design.md`, sostituire
"un file per stato col raw value dello stato" con
"un file per stato col **nome del case** (`SessionState` è Int-backed)".

- [ ] **Step 6: Commit**

```bash
git add App/Sources/VedettaKit/MascotFrame.swift App/Tests/VedettaKitTests/MascotFrameTests.swift docs/superpowers/specs/2026-07-23-branding-design.md
git commit -m "feat: MascotFrame — cat patterns and pure per-state frame selection"
```

---

### Task 2: IndicatorFrames (VedettaKit) — dual-chase e squash

**Files:**
- Create: `App/Sources/VedettaKit/IndicatorFrames.swift`
- Test: `App/Tests/VedettaKitTests/IndicatorFramesTests.swift`

**Interfaces:**
- Produces: `IndicatorFrames.ring: [(x: Int, y: Int)]` (8 celle, perimetro 3×3 orario da alto-sx); `IndicatorFrames.dualChaseAlpha(index:tick:) -> Double`; `IndicatorFrames.squashHeights = [4,3,2,1,2,3]`; `IndicatorFrames.squashRowCount(tick:) -> Int`.

- [ ] **Step 1: Scrivi il test che fallisce**

```swift
import Testing
@testable import VedettaKit

struct IndicatorFramesTests {
    @Test func ringHasEightCellsClockwise() {
        #expect(IndicatorFrames.ring.count == 8)
        #expect(IndicatorFrames.ring[0].x == 0 && IndicatorFrames.ring[0].y == 0)
        #expect(IndicatorFrames.ring[4].x == 2 && IndicatorFrames.ring[4].y == 2)
    }

    @Test func dualChaseHasTwoOppositeHeads() {
        // A tick 0 le teste sono alle posizioni 0 e 4 (alpha piena).
        #expect(IndicatorFrames.dualChaseAlpha(index: 0, tick: 0) == 1.0)
        #expect(IndicatorFrames.dualChaseAlpha(index: 4, tick: 0) == 1.0)
        // Una cella dietro ciascuna testa: alpha 0.7.
        #expect(abs(IndicatorFrames.dualChaseAlpha(index: 1, tick: 0) - 0.7) < 0.001)
        #expect(abs(IndicatorFrames.dualChaseAlpha(index: 5, tick: 0) - 0.7) < 0.001)
        // Equidistante dalle due teste (d=2): alpha 0.4.
        #expect(abs(IndicatorFrames.dualChaseAlpha(index: 2, tick: 0) - 0.4) < 0.001)
    }

    @Test func dualChaseAdvancesWithTick() {
        #expect(IndicatorFrames.dualChaseAlpha(index: 1, tick: 1) == 1.0)
        #expect(IndicatorFrames.dualChaseAlpha(index: 5, tick: 1) == 1.0)
    }

    @Test func squashCyclesThroughHeights() {
        #expect((0...5).map { IndicatorFrames.squashRowCount(tick: $0) } == [4, 3, 2, 1, 2, 3])
        #expect(IndicatorFrames.squashRowCount(tick: 6) == 4)   // il ciclo riparte
    }
}
```

- [ ] **Step 2: Verifica che fallisca**

Run: `make test`
Expected: FAIL — "cannot find 'IndicatorFrames' in scope"

- [ ] **Step 3: Implementazione minima**

```swift
// App/Sources/VedettaKit/IndicatorFrames.swift

/// Pure math for the pixel state indicators: the running dual-chase
/// spinner and the compacting squash column. Views sample these with
/// PixelClock ticks; tests pin the cycles.
public enum IndicatorFrames {
    /// Perimeter of a 3×3 grid, clockwise from the top-left corner.
    public static let ring: [(x: Int, y: Int)] = [
        (0, 0), (1, 0), (2, 0), (2, 1), (2, 2), (1, 2), (0, 2), (0, 1),
    ]

    /// Two opposite heads chasing on the ring; each cell fades with its
    /// distance from the nearest head.
    public static func dualChaseAlpha(index: Int, tick: Int) -> Double {
        let d1 = (((index - tick) % 8) + 8) % 8
        let d2 = (((index - tick - 4) % 8) + 8) % 8
        return max(0, 1 - Double(min(d1, d2)) * 0.3)
    }

    /// Lit-row cycle of the compacting column (squash and re-expand).
    public static let squashHeights = [4, 3, 2, 1, 2, 3]

    public static func squashRowCount(tick: Int) -> Int {
        let n = squashHeights.count
        return squashHeights[((tick % n) + n) % n]
    }
}
```

- [ ] **Step 4: Verifica che passi**

Run: `make test`
Expected: PASS (+4 test)

- [ ] **Step 5: Commit**

```bash
git add App/Sources/VedettaKit/IndicatorFrames.swift App/Tests/VedettaKitTests/IndicatorFramesTests.swift
git commit -m "feat: IndicatorFrames — dual-chase alphas and squash cycle"
```

---

### Task 3: StateIndicator — dual-chase running, squash compacting

**Files:**
- Modify: `App/Sources/Vedetta/UI/StateIndicator.swift`

**Interfaces:**
- Consumes: `IndicatorFrames` (Task 2), `PixelClock` (esistente, stesso file), `Theme` (esistente).
- Produces: `PixelClock.tick(_ step: TimeInterval) -> Int`; view `DualChaseSpinner(color:cell:)`; view `CompactingSquash(color:cell:)`. `PixelSpinner` e `spinTick` vengono rimossi.

- [ ] **Step 1: Verifica chi usa PixelSpinner/spinTick**

Run: `grep -rn "PixelSpinner\|spinTick" App/Sources/`
Expected: solo `StateIndicator.swift` (se compare altrove, aggiorna anche lì con `DualChaseSpinner`).

- [ ] **Step 2: Sostituisci spinner e aggiungi squash**

In `StateIndicator.swift`:

1. In `PixelClock`, sostituisci `spinTick` con il tick generico:

```swift
    /// Frame counter for step-driven animations (spinner 0.12s, squash 0.15s).
    func tick(_ step: TimeInterval) -> Int {
        Int(now.timeIntervalSinceReferenceDate / step)
    }
```

2. Nel `body` di `StateIndicator`, aggiorna i due case:

```swift
        case .running:
            DualChaseSpinner(cell: 3 * scale)
        case .compacting:
            CompactingSquash(cell: 3 * scale)
```

3. Rimuovi l'intera `struct PixelSpinner` e al suo posto:

```swift
/// 8-bit spinner: two opposite blocks chasing each other around the
/// perimeter of a square, each cell fading with distance from a head.
struct DualChaseSpinner: View {
    @ObservedObject private var clock = PixelClock.shared
    var color: Color = Theme.toolBlue
    var cell: CGFloat = 3

    var body: some View {
        let tick = clock.tick(0.12)
        Canvas { gc, _ in
            let inset = cell * 0.07
            for (i, p) in IndicatorFrames.ring.enumerated() {
                let alpha = IndicatorFrames.dualChaseAlpha(index: i, tick: tick)
                guard alpha > 0 else { continue }
                let rect = CGRect(
                    x: CGFloat(p.x) * cell + inset,
                    y: CGFloat(p.y) * cell + inset,
                    width: cell - inset * 2,
                    height: cell - inset * 2
                )
                gc.fill(Path(rect), with: .color(color.opacity(alpha)))
            }
        }
        .frame(width: cell * 3, height: cell * 3)
        .shadow(color: color.opacity(0.8), radius: cell * 1.4)
    }
}

/// Compacting: a two-cell-wide column that squashes down to one row and
/// re-expands in steps — the context being compressed.
struct CompactingSquash: View {
    @ObservedObject private var clock = PixelClock.shared
    var color: Color = Theme.color(for: .compacting)
    var cell: CGFloat = 3

    var body: some View {
        let rows = IndicatorFrames.squashRowCount(tick: clock.tick(0.15))
        let maxRows = IndicatorFrames.squashHeights.max() ?? 4
        Canvas { gc, _ in
            let inset = cell * 0.07
            let top = CGFloat(maxRows - rows) * cell / 2
            for r in 0..<rows {
                let rect = CGRect(
                    x: inset,
                    y: top + CGFloat(r) * cell + inset,
                    width: cell * 2 - inset * 2,
                    height: cell - inset * 2
                )
                gc.fill(Path(rect), with: .color(color))
            }
        }
        .frame(width: cell * 2, height: cell * CGFloat(maxRows))
        .shadow(color: color.opacity(0.8), radius: cell * 1.4)
    }
}
```

- [ ] **Step 3: Build e test**

Run: `make test && make app`
Expected: test verdi, build ok.

- [ ] **Step 4: Verifica visiva rapida**

Run: `open dist/Vedetta.app`, avvia una sessione Claude di prova → nella card lo spinner blu ha due teste opposte; (il compacting si verifica in Task 9 con una sessione reale o un `decide`/dump di stato).

- [ ] **Step 5: Commit**

```bash
git add App/Sources/Vedetta/UI/StateIndicator.swift
git commit -m "feat: dual-chase running spinner and compacting squash indicator"
```

---

### Task 4: MascotSprite — il gattino su card, notch e onboarding

**Files:**
- Create: `App/Sources/Vedetta/UI/MascotSprite.swift`
- Modify: `App/Sources/Vedetta/UI/SessionRowView.swift` (righe ~90-101, blocco sprite)
- Modify: `App/Sources/Vedetta/UI/NotchView.swift` (riga ~139 collapsed + helper)
- Modify: `App/Sources/Vedetta/OnboardingController.swift` (welcome ~112, allSet ~236)
- Modify: `App/Sources/Vedetta/UI/PixelSprite.swift` (rimuovi `lookout`)

**Interfaces:**
- Consumes: `MascotFrame` (Task 1), `PixelClock` (Task 3), `PixelSprite` (esistente), `AgentSession.stateChangedAt` (esistente).
- Produces: view `MascotSprite(state:stateChangedAt:color:pixelSize:)`.

- [ ] **Step 1: Crea la view**

```swift
// App/Sources/Vedetta/UI/MascotSprite.swift
import SwiftUI
import VedettaKit

/// The guard cat: samples MascotFrame on every PixelClock tick so the
/// eyes scan/blink per state and the ears twitch right after an event.
struct MascotSprite: View {
    @ObservedObject private var clock = PixelClock.shared
    let state: SessionState
    var stateChangedAt: Date = .distantPast
    var color: Color
    var pixelSize: CGFloat = 2.5

    var body: some View {
        PixelSprite(
            pattern: MascotFrame.frame(
                state: state,
                now: clock.now,
                stateChangedAt: stateChangedAt,
                blinkOn: clock.blinkOn
            ),
            color: color,
            pixelSize: pixelSize
        )
    }
}
```

- [ ] **Step 2: Card di sessione**

In `SessionRowView.swift`, sostituisci il blocco sprite di `fullRow` (le due `PixelSprite(pattern: PixelSprite.lookout, …)`):

```swift
                    MascotSprite(
                        state: session.state,
                        stateChangedAt: session.stateChangedAt,
                        color: Theme.color(for: session.state),
                        pixelSize: 2.2
                    )
                    if session.subagentCount > 0 {
                        MascotSprite(
                            state: session.state,
                            stateChangedAt: session.stateChangedAt,
                            color: Theme.color(for: session.state).opacity(0.8),
                            pixelSize: 1.4
                        )
                    }
```

- [ ] **Step 3: Notch collassato**

In `NotchView.swift`, sostituisci la riga 139 (`PixelSprite(pattern: PixelSprite.lookout, color: statusColor, pixelSize: 2)`):

```swift
            MascotSprite(
                state: collapsedTopState ?? .completed,
                stateChangedAt: collapsedTopSession?.stateChangedAt ?? .distantPast,
                color: statusColor,
                pixelSize: 2
            )
```

e accanto a `collapsedTopState` (riga ~190) aggiungi:

```swift
    /// The session that owns the collapsed sprite's expression: the most
    /// recently-changed one among those in the top state.
    private var collapsedTopSession: AgentSession? {
        guard let top = collapsedTopState else { return nil }
        return visibleSessions.filter { $0.state == top }
            .max { $0.stateChangedAt < $1.stateChangedAt }
    }
```

(Senza sessioni il gatto resta grigio a occhi chiusi — dorme: comportamento voluto.)

- [ ] **Step 4: Onboarding**

In `OnboardingController.swift` aggiungi `import VedettaKit` e sostituisci i due
`PixelSprite(pattern: PixelSprite.lookout, color: step.accent, pixelSize: 9)` (welcome)
e `pixelSize: 7` (allSet) con:

```swift
            PixelSprite(
                pattern: MascotFrame.base,
                color: step.accent,
                pixelSize: 9
            )
```

(e `pixelSize: 7` nel passo allSet).

- [ ] **Step 5: Rimuovi il lookout**

In `PixelSprite.swift` elimina la static `lookout`, poi:

Run: `grep -rn "lookout" App/Sources/ && echo "RESIDUI" || echo "PULITO"`
Expected: `PULITO`

- [ ] **Step 6: Build, test, verifica live**

Run: `make test && make app && open dist/Vedetta.app`
Expected: test verdi; con una sessione Claude live la card mostra il gatto con occhi che scansionano (blu), blink in attesa (verde), twitch al cambio stato; notch collassato col gatto; onboarding (Settings → About → Show) col gatto grande.

- [ ] **Step 7: Commit**

```bash
git add App/Sources/Vedetta/UI/MascotSprite.swift App/Sources/Vedetta/UI/SessionRowView.swift App/Sources/Vedetta/UI/NotchView.swift App/Sources/Vedetta/OnboardingController.swift App/Sources/Vedetta/UI/PixelSprite.swift
git commit -m "feat: the guard cat replaces the invader on cards, notch and onboarding"
```

---

### Task 5: Icona app — gattino + starfield

**Files:**
- Modify: `scripts/render-icon.swift` (riscrittura completa)

**Interfaces:**
- Consumes: niente dal target app (script standalone; il pattern è duplicato di proposito).
- Produces: `dist/AppIcon.icns` via `scripts/make-icon.sh` (invariato).

- [ ] **Step 1: Riscrivi lo script**

```swift
// Renders Vedetta's app icon: the guard cat under a pixel starfield on a
// dark rounded tile. Usage: swift render-icon.swift out.png
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let size = 1024
let sprite = [
    ".#....#.",
    ".##..##.",
    ".######.",
    ".#o##o#.",
    ".######.",
    "..####..",
    "..#..#..",
]

let context = CGContext(
    data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
    space: CGColorSpace(name: CGColorSpace.sRGB)!,
    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
)!

// tile scuro con angoli macOS
let inset = CGFloat(size) * 0.09
let tile = CGRect(x: inset, y: inset, width: CGFloat(size) - inset * 2, height: CGFloat(size) - inset * 2)
let path = CGPath(roundedRect: tile, cornerWidth: tile.width * 0.22, cornerHeight: tile.width * 0.22, transform: nil)
context.addPath(path)
context.setFillColor(CGColor(red: 0.047, green: 0.055, blue: 0.047, alpha: 1))
context.fillPath()

context.saveGState()
context.addPath(path)
context.clip()

// starfield deterministico (stesso LCG di StarfieldView)
var seed: UInt64 = 0x5EED_CAFE
func next() -> CGFloat {
    seed = seed &* 6364136223846793005 &+ 1442695040888963407
    return CGFloat(seed >> 33) / CGFloat(UInt32.max >> 1)
}
for _ in 0..<24 {
    let x = tile.minX + next() * tile.width
    let y = tile.minY + next() * tile.height
    let side = (next() > 0.72 ? 2.2 : 1.4) * CGFloat(size) / 128
    let alpha = 0.2 + Double(next()) * 0.3
    context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: alpha))
    context.fill(CGRect(x: x, y: y, width: side, height: side))
}

// gatto centrato con glow
let columns = sprite[0].count, rows = sprite.count
let pixel = tile.width * 0.68 / CGFloat(columns)
let originX = tile.midX - pixel * CGFloat(columns) / 2
let originY = tile.midY - pixel * CGFloat(rows) / 2
let green = CGColor(red: 0.42, green: 0.78, blue: 0.48, alpha: 1)
context.setShadow(offset: .zero, blur: pixel * 1.1, color: CGColor(red: 0.42, green: 0.78, blue: 0.48, alpha: 0.85))
context.setFillColor(green)
for (row, line) in sprite.enumerated() {
    for (col, char) in line.enumerated() where char == "#" {
        let rect = CGRect(
            x: originX + CGFloat(col) * pixel + pixel * 0.06,
            y: originY + CGFloat(rows - 1 - row) * pixel + pixel * 0.06,
            width: pixel * 0.88, height: pixel * 0.88
        )
        context.fill(rect)
    }
}
context.restoreGState()

let image = context.makeImage()!
let url = URL(fileURLWithPath: CommandLine.arguments[1]) as CFURL
let destination = CGImageDestinationCreateWithURL(url, UTType.png.identifier as CFString, 1, nil)!
CGImageDestinationAddImage(destination, image, nil)
CGImageDestinationFinalize(destination)
```

- [ ] **Step 2: Genera e verifica la leggibilità (gate 32px)**

Run:
```bash
sh scripts/make-icon.sh
swift scripts/render-icon.swift /tmp/vedetta-icon-check.png && sips -z 32 32 /tmp/vedetta-icon-check.png --out /tmp/vedetta-icon-32.png
```
Expected: `Icon: …/dist/AppIcon.icns`; aprire/leggere `/tmp/vedetta-icon-32.png`: le orecchie del gatto devono restare distinguibili (se a 32px le stelle sporcano, ridurre le stelle a 16 o alzare la soglia alpha).

- [ ] **Step 3: Rebuild app con l'icona nuova**

Run: `make app && open dist/Vedetta.app`
Expected: icona nuova nel Dock (gatto verde su cielo stellato).

- [ ] **Step 4: Commit**

```bash
git add scripts/render-icon.swift
git commit -m "feat: app icon — guard cat under a pixel starfield"
```

---

### Task 6: DMG — background e layout Finder

**Files:**
- Create: `scripts/render-dmg-bg.swift`
- Modify: `scripts/make-dmg.sh` (riscrittura completa)

**Interfaces:**
- Consumes: `dist/Vedetta.app` (da `make app`).
- Produces: `dist/Vedetta.dmg` con background, icone posizionate, icon size 128.

- [ ] **Step 1: Script del background**

```swift
// scripts/render-dmg-bg.swift
// Renders the DMG background: black starfield, pixel arrow, typewriter
// caption. 1200×800 px tagged 144 dpi (renders as 600×400 pt).
// Usage: swift render-dmg-bg.swift out.png
import AppKit
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let W = 1200, H = 800
let context = CGContext(
    data: nil, width: W, height: H, bitsPerComponent: 8, bytesPerRow: 0,
    space: CGColorSpace(name: CGColorSpace.sRGB)!,
    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
)!

// notte
context.setFillColor(CGColor(red: 0.016, green: 0.027, blue: 0.016, alpha: 1))
context.fill(CGRect(x: 0, y: 0, width: W, height: H))

// starfield deterministico
var seed: UInt64 = 0x5EED_CAFE
func next() -> CGFloat {
    seed = seed &* 6364136223846793005 &+ 1442695040888963407
    return CGFloat(seed >> 33) / CGFloat(UInt32.max >> 1)
}
for _ in 0..<70 {
    let x = next() * CGFloat(W)
    let y = next() * CGFloat(H)
    let side: CGFloat = next() > 0.72 ? 4 : 2.6
    let alpha = 0.2 + Double(next()) * 0.5
    context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: alpha))
    context.fill(CGRect(x: x, y: y, width: side, height: side))
}

// freccia pixel tra le due icone (posizionate a ~300 e ~900 px, y centro ~430 dal basso)
let green = CGColor(red: 0.42, green: 0.78, blue: 0.48, alpha: 1)
let b: CGFloat = 22
let ay = CGFloat(H) * 0.54
let ax = CGFloat(W) / 2 - b * 3.1
context.setShadow(offset: .zero, blur: 16, color: CGColor(red: 0.42, green: 0.78, blue: 0.48, alpha: 0.8))
context.setFillColor(green)
for i in 0..<3 {
    context.fill(CGRect(x: ax + CGFloat(i) * b * 1.25, y: ay, width: b, height: b))
}
let hx = ax + 3 * b * 1.25
context.fill(CGRect(x: hx, y: ay - b * 1.25, width: b, height: b))
context.fill(CGRect(x: hx, y: ay, width: b, height: b))
context.fill(CGRect(x: hx, y: ay + b * 1.25, width: b, height: b))
context.fill(CGRect(x: hx + b * 1.25, y: ay, width: b, height: b))
context.setShadow(offset: .zero, blur: 0, color: nil)

// riga typewriter in basso, centrata
let ns = NSGraphicsContext(cgContext: context, flipped: false)
NSGraphicsContext.current = ns
let attrs: [NSAttributedString.Key: Any] = [
    .font: NSFont.monospacedSystemFont(ofSize: 28, weight: .regular),
    .foregroundColor: NSColor(white: 1, alpha: 0.55),
]
let caption = NSAttributedString(string: "> drag to install _", attributes: attrs)
let captionSize = caption.size()
caption.draw(at: NSPoint(x: (CGFloat(W) - captionSize.width) / 2, y: CGFloat(H) * 0.10))
NSGraphicsContext.current = nil

// PNG a 144 dpi
let image = context.makeImage()!
let url = URL(fileURLWithPath: CommandLine.arguments[1]) as CFURL
let destination = CGImageDestinationCreateWithURL(url, UTType.png.identifier as CFString, 1, nil)!
let props: [CFString: Any] = [kCGImagePropertyDPIWidth: 144, kCGImagePropertyDPIHeight: 144]
CGImageDestinationAddImage(destination, image, props as CFDictionary)
CGImageDestinationFinalize(destination)
```

- [ ] **Step 2: make-dmg.sh con layout**

```sh
#!/bin/sh
# Packages dist/Vedetta.app into dist/Vedetta.dmg with the 8-bit background.
set -eu
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/dist/Vedetta.app"
DMG="$ROOT/dist/Vedetta.dmg"
RW="$ROOT/dist/Vedetta-rw.dmg"
STAGE="$ROOT/dist/dmg-stage"
BG="$ROOT/dist/dmg-bg.png"

[ -d "$APP" ] || "$ROOT/scripts/make-app.sh"
swift "$ROOT/scripts/render-dmg-bg.swift" "$BG"

rm -rf "$STAGE" "$DMG" "$RW"
mkdir -p "$STAGE/.background"
cp -R "$APP" "$STAGE/"
cp "$BG" "$STAGE/.background/bg.png"
ln -s /Applications "$STAGE/Applications"

hdiutil create -volname "Vedetta" -srcfolder "$STAGE" -ov -format UDRW "$RW" >/dev/null
MOUNT_OUT="$(hdiutil attach -readwrite -noverify -noautoopen "$RW")"
MOUNT="$(printf '%s\n' "$MOUNT_OUT" | awk -F'\t' '/\/Volumes\//{print $3}')"

osascript <<'EOF'
tell application "Finder"
    tell disk "Vedetta"
        open
        set current view of container window to icon view
        set toolbar visible of container window to false
        set statusbar visible of container window to false
        set the bounds of container window to {200, 140, 800, 540}
        set viewOptions to the icon view options of container window
        set arrangement of viewOptions to not arranged
        set icon size of viewOptions to 128
        set background picture of viewOptions to file ".background:bg.png"
        set position of item "Vedetta.app" of container window to {150, 185}
        set position of item "Applications" of container window to {450, 185}
        update without registering applications
        delay 1
        close
    end tell
end tell
EOF

sync
hdiutil detach "$MOUNT" >/dev/null
hdiutil convert "$RW" -format UDZO -o "$DMG" >/dev/null
rm -rf "$STAGE" "$RW" "$BG"
echo "DMG: $DMG"
```

- [ ] **Step 3: Genera e verifica montando**

Run: `sh scripts/make-dmg.sh && open dist/Vedetta.dmg`
Expected: la finestra si apre con starfield, icona app a sinistra, Applications a destra, freccia tra le due, riga "> drag to install _" in basso. (Il primo run può chiedere il permesso Automation per Finder: concederlo.) Poi `hdiutil detach` del volume.

- [ ] **Step 4: Commit**

```bash
git add scripts/render-dmg-bg.swift scripts/make-dmg.sh
git commit -m "feat: dmg background — starfield, pixel arrow, typewriter caption"
```

---

### Task 7: CustomSpriteLibrary (VedettaKit) — risoluzione GIF per stato

**Files:**
- Create: `App/Sources/VedettaKit/CustomSpriteLibrary.swift`
- Test: `App/Tests/VedettaKitTests/CustomSpriteLibraryTests.swift`

**Interfaces:**
- Consumes: `SessionState` (esistente).
- Produces: `CustomSpriteLibrary(directory:)`; `CustomSpriteLibrary.standard`; `CustomSpriteLibrary.enabledKey = "customSpritesEnabled"`; `fileName(for:) -> String` (statico); `fileURL(for:) -> URL`; `url(for:) -> URL?` (nil se il file manca); `install(_:for:) throws -> URL`; `remove(for:) throws`.

- [ ] **Step 1: Scrivi il test che fallisce**

```swift
import Foundation
import Testing
@testable import VedettaKit

struct CustomSpriteLibraryTests {
    private func makeLibrary() throws -> (CustomSpriteLibrary, URL) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("vedetta-sprites-\(UUID().uuidString)", isDirectory: true)
        return (CustomSpriteLibrary(directory: dir), dir)
    }

    @Test func fileNamesUseCaseNames() {
        #expect(CustomSpriteLibrary.fileName(for: .running) == "running.gif")
        #expect(CustomSpriteLibrary.fileName(for: .waitingForInput) == "waitingForInput.gif")
        #expect(CustomSpriteLibrary.fileName(for: .needsApproval) == "needsApproval.gif")
        #expect(CustomSpriteLibrary.fileName(for: .compacting) == "compacting.gif")
        #expect(CustomSpriteLibrary.fileName(for: .completed) == "completed.gif")
    }

    @Test func urlIsNilWithoutFile() throws {
        let (library, _) = try makeLibrary()
        #expect(library.url(for: .running) == nil)
    }

    @Test func installCopiesAndResolves() throws {
        let (library, dir) = try makeLibrary()
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = FileManager.default.temporaryDirectory
            .appendingPathComponent("fake-\(UUID().uuidString).gif")
        try Data([0x47, 0x49, 0x46]).write(to: source)
        defer { try? FileManager.default.removeItem(at: source) }

        let dest = try library.install(source, for: .running)
        #expect(library.url(for: .running) == dest)
        #expect(dest.lastPathComponent == "running.gif")
        #expect(library.url(for: .waitingForInput) == nil)   // gli altri stati restano fallback
    }

    @Test func installReplacesAndRemoveClears() throws {
        let (library, dir) = try makeLibrary()
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = FileManager.default.temporaryDirectory
            .appendingPathComponent("fake-\(UUID().uuidString).gif")
        try Data([0x01]).write(to: source)
        try library.install(source, for: .completed)
        try Data([0x02, 0x03]).write(to: source)
        try library.install(source, for: .completed)          // rimpiazza senza errore
        defer { try? FileManager.default.removeItem(at: source) }

        let installed = try #require(library.url(for: .completed))
        #expect(try Data(contentsOf: installed) == Data([0x02, 0x03]))
        try library.remove(for: .completed)
        #expect(library.url(for: .completed) == nil)
        try library.remove(for: .completed)                   // idempotente
    }
}
```

- [ ] **Step 2: Verifica che fallisca**

Run: `make test`
Expected: FAIL — "cannot find 'CustomSpriteLibrary' in scope"

- [ ] **Step 3: Implementazione minima**

```swift
// App/Sources/VedettaKit/CustomSpriteLibrary.swift
import Foundation

/// Per-state custom sprite GIFs in ~/.vedetta/custom-sprites/. Pure file
/// resolution: a state resolves to a URL only when its GIF exists, so
/// callers fall back to the mascot everywhere else. File names use the
/// SessionState case names (the enum is Int-backed).
public struct CustomSpriteLibrary: Sendable {
    public static let enabledKey = "customSpritesEnabled"
    public static let standard = CustomSpriteLibrary(
        directory: FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".vedetta/custom-sprites", isDirectory: true)
    )

    public let directory: URL

    public init(directory: URL) {
        self.directory = directory
    }

    public static func fileName(for state: SessionState) -> String {
        switch state {
        case .needsApproval: "needsApproval.gif"
        case .running: "running.gif"
        case .compacting: "compacting.gif"
        case .waitingForInput: "waitingForInput.gif"
        case .completed: "completed.gif"
        }
    }

    public func fileURL(for state: SessionState) -> URL {
        directory.appendingPathComponent(Self.fileName(for: state))
    }

    /// URL only when the GIF is actually there.
    public func url(for state: SessionState) -> URL? {
        let url = fileURL(for: state)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    @discardableResult
    public func install(_ source: URL, for state: SessionState) throws -> URL {
        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        let dest = fileURL(for: state)
        if fm.fileExists(atPath: dest.path) {
            try fm.removeItem(at: dest)
        }
        try fm.copyItem(at: source, to: dest)
        return dest
    }

    public func remove(for state: SessionState) throws {
        let dest = fileURL(for: state)
        if FileManager.default.fileExists(atPath: dest.path) {
            try FileManager.default.removeItem(at: dest)
        }
    }
}
```

- [ ] **Step 4: Verifica che passi**

Run: `make test`
Expected: PASS (+4 test)

- [ ] **Step 5: Commit**

```bash
git add App/Sources/VedettaKit/CustomSpriteLibrary.swift App/Tests/VedettaKitTests/CustomSpriteLibraryTests.swift
git commit -m "feat: CustomSpriteLibrary — per-state gif resolution with fallback"
```

---

### Task 8: GIF nelle card e Settings → Display "Sprite"

**Files:**
- Create: `App/Sources/Vedetta/UI/AnimatedImageView.swift`
- Create: `App/Sources/Vedetta/UI/SessionSpriteView.swift`
- Modify: `App/Sources/Vedetta/UI/SessionRowView.swift` (lo sprite principale di Task 4)
- Modify: `App/Sources/Vedetta/UI/NotchView.swift` (lo sprite collassato di Task 4)
- Modify: `App/Sources/Vedetta/Settings/SettingsView.swift` (`DisplaySettingsPage`, ~riga 450)

**Interfaces:**
- Consumes: `CustomSpriteLibrary` (Task 7), `MascotSprite` (Task 4), `SettingsSection`/`SettingsRow`/`RowDivider` (esistenti in SettingsView), `Theme.label(for:)` (esistente).
- Produces: `AnimatedImageView(url:targetHeight:)`; `SessionSpriteView(state:stateChangedAt:color:pixelSize:)` — il punto unico che decide GIF vs mascotte.

- [ ] **Step 1: AnimatedImageView**

```swift
// App/Sources/Vedetta/UI/AnimatedImageView.swift
import AppKit
import SwiftUI

/// Animated GIF for custom sprites: NSImageView animates GIFs natively.
/// Height-capped with preserved aspect, never upscaled past the image's
/// own pixel height.
struct AnimatedImageView: NSViewRepresentable {
    let url: URL
    let targetHeight: CGFloat

    func makeNSView(context: Context) -> NSImageView {
        let view = NSImageView()
        view.animates = true
        view.imageScaling = .scaleProportionallyDown
        view.image = NSImage(contentsOf: url)
        return view
    }

    func updateNSView(_ view: NSImageView, context: Context) {}

    func sizeThatFits(
        _ proposal: ProposedViewSize, nsView: NSImageView, context: Context
    ) -> CGSize? {
        guard let size = nsView.image?.size, size.height > 0 else {
            return CGSize(width: targetHeight, height: targetHeight)
        }
        let height = min(targetHeight, size.height)
        return CGSize(width: size.width * height / size.height, height: height)
    }
}
```

- [ ] **Step 2: SessionSpriteView (GIF se c'è, gatto altrimenti)**

```swift
// App/Sources/Vedetta/UI/SessionSpriteView.swift
import SwiftUI
import VedettaKit

/// The session sprite slot: the user's per-state GIF when custom sprites
/// are enabled and the file exists, the guard cat otherwise. No tint on
/// GIFs — state color stays on indicators and text.
struct SessionSpriteView: View {
    let state: SessionState
    var stateChangedAt: Date = .distantPast
    var color: Color
    var pixelSize: CGFloat
    @AppStorage(CustomSpriteLibrary.enabledKey) private var customEnabled = false

    var body: some View {
        if customEnabled, let url = CustomSpriteLibrary.standard.url(for: state) {
            AnimatedImageView(url: url, targetHeight: 7 * pixelSize)
                .id(url)
        } else {
            MascotSprite(
                state: state,
                stateChangedAt: stateChangedAt,
                color: color,
                pixelSize: pixelSize
            )
        }
    }
}
```

- [ ] **Step 3: Aggancia card e notch**

In `SessionRowView.swift` sostituisci la `MascotSprite(state: session.state, … pixelSize: 2.2)` principale (NON la mini-subagent, che resta gatto) con:

```swift
                    SessionSpriteView(
                        state: session.state,
                        stateChangedAt: session.stateChangedAt,
                        color: Theme.color(for: session.state),
                        pixelSize: 2.2
                    )
```

In `NotchView.swift` sostituisci la `MascotSprite(… pixelSize: 2)` del collassato con:

```swift
            SessionSpriteView(
                state: collapsedTopState ?? .completed,
                stateChangedAt: collapsedTopSession?.stateChangedAt ?? .distantPast,
                color: statusColor,
                pixelSize: 2
            )
```

- [ ] **Step 4: Sezione Settings**

In `SettingsView.swift`, dentro `DisplaySettingsPage` aggiungi lo state
`@AppStorage(CustomSpriteLibrary.enabledKey) private var customSprites = false`
e, dopo la SettingsSection "Notch" esistente, la sezione:

```swift
        SettingsSection(
            title: "Sprite",
            footer: "GIFs live in ~/.vedetta/custom-sprites, one per state; the cat fills the gaps. Scaled to the sprite height, never blown up."
        ) {
            SettingsRow(
                title: "Custom sprites",
                subtitle: "Replace the cat with your own GIFs, per state."
            ) {
                Toggle("", isOn: $customSprites)
                    .toggleStyle(.switch)
                    .labelsHidden()
            }
            if customSprites {
                ForEach(SessionState.allCases, id: \.self) { state in
                    RowDivider()
                    SpriteFileRow(state: state)
                }
            }
        }
```

e in fondo al file la row (privata, stesso file):

```swift
private struct SpriteFileRow: View {
    let state: SessionState
    @State private var installed = false

    var body: some View {
        SettingsRow(
            title: Theme.label(for: state).capitalized,
            subtitle: installed
                ? CustomSpriteLibrary.fileName(for: state)
                : "Built-in cat"
        ) {
            HStack(spacing: 8) {
                Button("Choose…") { choose() }
                if installed {
                    Button("Reset") {
                        try? CustomSpriteLibrary.standard.remove(for: state)
                        refresh()
                    }
                }
            }
        }
        .onAppear(perform: refresh)
    }

    private func refresh() {
        installed = CustomSpriteLibrary.standard.url(for: state) != nil
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.gif]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? CustomSpriteLibrary.standard.install(url, for: state)
        refresh()
    }
}
```

(`SettingsView.swift` importa già `VedettaKit`; verifica in testa al file, altrimenti aggiungilo.)

- [ ] **Step 5: Build, test, e2e con GIF di prova**

Run: `make test && make app && open dist/Vedetta.app`
Poi: Settings → Display → attiva "Custom sprites" → Choose… una GIF qualsiasi per `running` → con una sessione live in running la card mostra la GIF (altezza card invariata); gli altri stati restano gatto; Reset → torna il gatto.
Expected: nessun jump di layout; GIF animata; fallback corretto.

- [ ] **Step 6: Commit**

```bash
git add App/Sources/Vedetta/UI/AnimatedImageView.swift App/Sources/Vedetta/UI/SessionSpriteView.swift App/Sources/Vedetta/UI/SessionRowView.swift App/Sources/Vedetta/UI/NotchView.swift App/Sources/Vedetta/Settings/SettingsView.swift
git commit -m "feat: per-state custom sprite gifs with settings and mascot fallback"
```

---

### Task 9: Verifica end-to-end, docs e chiusura

**Files:**
- Modify: `docs/vi-binary-audit.md` (progress log: nuova entry di sessione)
- Modify: `docs/superpowers/plans/2026-07-23-branding-implementation.md` (checkbox)

**Interfaces:** nessuna nuova — solo verifica e documentazione.

- [ ] **Step 1: Giro live completo (Claude + Codex)**

Con l'app buildata e una sessione reale per agente:
- card: gatto con scansione occhi (blu) mentre lavora, blink (verde) in attesa, spalancati+"?" su approvazione, twitch d'orecchie al cambio stato;
- indicatori: dual-chase blu; compacting viola a squash (aspettare un compact reale o forzarne uno con `/compact`);
- notch collassato: gatto col colore dello stato più urgente; senza sessioni dorme grigio;
- onboarding: gatto nei passi welcome/all-set;
- GIF custom: una GIF su `running`, fallback sugli altri, Reset ok;
- icona Dock e `dist/Vedetta.dmg` montato: verifica visiva.

- [ ] **Step 2: Registra le animazioni per il confronto frame-by-frame**

Run: registrazione .mov della card (⇧⌘5 o `screencapture -v`), poi `ffmpeg -i clip.mov -vf fps=15 frames/f%03d.png` e controlla scansione 0.36s / squash 0.15s / twitch doppio burst.

- [ ] **Step 3: Aggiorna l'audit**

In `docs/vi-binary-audit.md`, appendi al progress log una entry "Pass 8 — branding" con: decisioni dei 3 round (gattino 1B, icona 2C, DMG 3B, dual-chase, squash, "?" invariato, GIF 5B), file JSON in ~/Downloads, e gli esiti della verifica live.

- [ ] **Step 4: Commit docs**

```bash
git add docs/vi-binary-audit.md docs/superpowers/plans/2026-07-23-branding-implementation.md
git commit -m "docs: branding pass — decisions, implementation and live verification log"
```

- [ ] **Step 5: Conferma di Matteo**

Mostrare a Matteo il riepilogo e attendere la sua verifica manuale (regola di progetto: niente parità/completamento autodichiarato). Solo dopo il suo ok il branding è chiuso.
