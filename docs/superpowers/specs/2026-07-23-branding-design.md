# Branding Vedetta — design

Data: 2026-07-23 · Deciso con 3 round di ballot visivi interattivi
(`2026-07-22-branding-previews.html`, `…-r2.html`, `2026-07-23-…-r3.html`) +
JSON di scelta in ~/Downloads. Il linguaggio resta retro-terminal 8-bit: hard on/off,
niente fade, glow fosforo, timing di `PixelClock` (parità VI dove non deciso diversamente).

## Decisioni

| Tema | Scelta | Round |
|---|---|---|
| Mascotte | Gattino di guardia (1B), 8×7, espressioni per stato | R1+chat |
| Icona app | Gattino + starfield su tile scuro (2C) | R1, confermata R2 |
| Background DMG | Starfield minimale (3B) | R1 |
| Indicatore running | Spinner "doppio inseguimento" (R3-C) | R3 |
| Indicatore waiting | Barra 2×4 attuale (A) | R2 |
| Indicatore approval | "?" attuale, design e animazione invariati (A) | R2+R3 |
| Indicatore compacting | "Blocco che si schiaccia" (R2-C) | R2 |
| Indicatore completed | Nessuno, come oggi (A) | R2 |
| GIF custom | Una per stato con fallback alla mascotte (5B) | R1 |

Nota compacting: nel round 3 la scelta dello spinner riguarda **solo il running**;
il compacting tiene lo squash scelto esplicitamente nel round 2 (nessuna nota contraria).

## 1 · Mascotte — il gattino di guardia

Sostituisce il glifo invader (`PixelSprite.lookout`) ovunque, **stessa griglia 8×7 e
stessi pixelSize** (card 2.2, mini-subagent 1.4, notch collassato 2.0, onboarding 9 e 7).
Il corpo prende il colore dello stato come oggi; gli occhi sono pixel spenti.

Pattern (`#` acceso, `o` occhio = spento, `.` vuoto):

```
base        sguardo sx   sguardo dx   spalancati   chiusi       twitch
.#....#.    .#....#.     .#....#.     .#....#.     .#....#.     ..#...#.
.##..##.    .##..##.     .##..##.     .##..##.     .##..##.     .##..##.
.######.    .######.     .######.     .######.     .######.     .######.
.#o##o#.    .o##o##.     .##o##o.     .#o##o#.     .######.     .#o##o#.
.######.    .######.     .######.     .#o##o#.     .#o##o#.     .######.
..####..    ..####..     ..####..     ..####..     ..####..     ..####..
..#..#..    ..#..#..     ..#..#..     ..#..#..     ..#..#..     ..#..#..
```

Espressioni per stato (clock condiviso `PixelClock`):

- **running / compacting** — scansione: sequenza `[base, sx, base, dx]`, step 0.36 s.
- **waitingForInput** — blink: `base` ↔ `chiusi` sincronizzato con `blinkOn` (1.2 s al 60%).
- **needsApproval** — `spalancati`, statico (l'urgenza la porta il "?" accanto).
- **completed** — `chiusi`, statico.
- **twitch d'orecchie** — all'arrivo di un evento (cambio di `stateChangedAt`): 2 burst
  del frame `twitch` entro 0.45 s (0–0.14 e 0.28–0.42), poi si torna all'espressione dello stato.

Implementazione: i pattern e la selezione frame vivono in un tipo puro testabile
(`MascotFrame.frame(state:now:stateChangedAt:)` o equivalente); `PixelSprite` resta il
renderer generico. `PixelSprite.lookout` viene rimosso.

## 2 · Indicatori di stato (`StateIndicator`)

- **running** — nuovo spinner **doppio inseguimento**: anello perimetrale 3×3 (cell 3 pt),
  due teste opposte (i e i+4), step 0.12 s, alpha per cella `1 − min(d1,d2)·0.3`. Blu `toolBlue`.
- **waiting** — `BlinkingBar` invariata (2×4, blink 1.2 s al 60%).
- **approval** — `BlinkingQuestionMark` invariato (glifo e punto blink attuali).
- **compacting** — nuovo **squash**: colonna larga 2 celle, altezze cicliche
  `[4, 3, 2, 1, 2, 3]`, step 0.15 s, viola `compactingPurple`. Sostituisce lo spinner viola.
- **completed** — nessun indicatore (parità VI).

`PixelClock` guadagna un tick generico (`tick(step:)`) per 0.36/0.15 s oltre agli esistenti.

## 3 · Icona app

Composizione 2C, generata da `scripts/render-icon.swift` riscritto:

- tile scuro `#0C0E0C`, inset 9%, corner radius 22% (invariati);
- starfield deterministico dentro il tile (~24 stelle, LCG identico a `StarfieldView`,
  bianco α 0.2–0.5, quadratini 1–2 px scala icona);
- gattino `base` centrato, verde `#6BC77A` con glow, `px = tile.w × 0.68 / 8`;
- occhi spenti: il tile traspare.

Pipeline `make-icon.sh`/iconutil invariata. Gate: leggibilità verificata a 32 px.

## 4 · DMG

- Nuovo `scripts/render-dmg-bg.swift`: PNG 1200×800 px marcato 144 dpi (600×400 pt),
  nero, starfield deterministico, freccia pixel verde chunky tra le posizioni delle icone,
  riga `> drag to install _` monospace in basso (underscore fisso: il PNG non anima).
- `make-dmg.sh` esteso: staging **UDRW** → mount → copia `.background/bg.png` →
  AppleScript (Finder) per background, icon size 128, finestra 600×400, posizioni
  app ≈ (150, 185) e /Applications ≈ (450, 185) → detach → convert **UDZO**.

## 5 · GIF custom per stato (Settings → Appearance)

Come i custom sounds, ma per lo sprite:

- Directory `~/.vedetta/custom-sprites/`, un file per stato col raw value dello stato:
  `running.gif`, `waitingForInput.gif`, `needsApproval.gif`, `compacting.gif`, `completed.gif`.
- **Fallback**: stato senza GIF → mascotte con l'espressione di quello stato.
- Rendering: `NSImageView` con `animates = true` (via `NSViewRepresentable`); altezza
  15 pt nella card e 14 pt nel notch collassato, aspect preservato, mai upscale oltre
  l'altezza target. Nessun tint: la GIF è dell'utente, il colore di stato resta
  su indicatori e testi.
- Settings → nuova sezione **Appearance**: toggle "Custom sprites" + per ogni stato un
  file well (Choose… copia il file nella directory / Reset lo rimuove). Nessun watcher:
  la lista si rilegge all'apertura del pannello e al toggle.

## Invarianti / fuori scope

- Suoni, approvals, hook, socket: intoccati.
- Timing e layout misurati su VI restano la bussola per tutto ciò che non è stato
  ridisegnato qui. Il branding (personaggio, icona, DMG) è deliberatamente originale.
- Onboarding: gli sprite `lookout` dei passi welcome/allSet passano al gattino, testi invariati.

## Test e verifica

- **Unit**: selezione frame mascotte (stato × tick × twitch window); ciclo altezze squash;
  alpha del doppio inseguimento; risoluzione GIF/fallback per presenza file.
- **E2E** (prima di dichiarare fatto, con conferma manuale di Matteo):
  sessioni live Claude+Codex → espressioni e twitch sulla card, indicatori per stato
  (compacting incluso), notch collassato; icona in Dock a 32/128; DMG montato e
  controllato a vista; GIF di prova per due stati con fallback sugli altri.
- Animazioni: verifica frame-by-frame con registrazione .mov + ffmpeg dove serve.

## File toccati (prevista)

`App/Sources/Vedetta/UI/PixelSprite.swift` (via lookout) · nuovo `UI/MascotSprite.swift` ·
`UI/StateIndicator.swift` · `UI/SessionRowView.swift` · `UI/NotchView.swift` ·
`OnboardingController.swift` · `Settings/SettingsView.swift` (+ Appearance) ·
`scripts/render-icon.swift` · nuovo `scripts/render-dmg-bg.swift` · `scripts/make-dmg.sh` ·
test in `Tests/`.
