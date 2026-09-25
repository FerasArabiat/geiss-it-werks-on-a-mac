# Geiss (original) — Feature Reference

A catalog of what the *original* Windows Geiss (source in `original/`) actually
does, extracted directly from `main.cpp` with file:line citations — not
paraphrased from general knowledge of "Geiss." This is the reference used to
scope `GeissMac`'s port; see `PORT_COVERAGE.md` for what's actually been
built so far against this list.

Two important caveats up front:

- **Mode numbers were renumbered at some point in the original's history.**
  Several comments in the per-pixel scale code (`main.cpp:4814` onward)
  reference an *old* numbering scheme ("mode 1: horz. tunnel" for what is
  now mode 17; "mode 5: vortex (**old mode 12**)" for what is now mode 19).
  The mode-number column below is the *current* numbering (what
  `GenerateChunkOfNewMap`'s `new_mode` switch actually uses, and what
  GeissMac's two-digit input also uses) — don't confuse an old-numbering
  comment for the current mode of the same number.
- Many keys/features only apply to 8-bit indexed color mode (`iDispBits==8`)
  and are no-ops in 32-bit truecolor, which is what GeissMac is modeled on
  (`FX_Random_Palette` starts with `if (iDispBits != 8) return;`). These
  are marked explicitly below.

## 1. Keyboard controls

Primary source: the original's own on-screen help text constants
(`main.cpp:1004-1025`, `szH1`-`szH10`) — this is the author's own wording of
what each key does. Supplemented with additional keys found in the
`WM_KEYDOWN`/`WM_CHAR` handling that aren't in the abbreviated help text.

| Key(s) | Original's own description | Notes |
|---|---|---|
| `Q` `E` `U` `G` `D` `A` `Y` | "control effects" (`szH1`, `main.cpp:1004`) | One key per overlay effect — see §3. Not the plasma "mode." |
| `O` (SAVER only) | "toggle sound" (`szH2`) | Starts/stops audio capture. |
| `SPACE` (PLUGIN only) | "show song title" (`szH2`) | Re-shows the Winamp title popup (main.cpp:7303-7311); the popup also fires on every title change (video.h:96-105). GeissMac ports it with the track from macOS Now Playing. |
| `J` `K` | "temporarily scale wave down/up" (`szH3`) | Mic input gain (`volpos`/`volscale`), ×0.8 / ×1.25 per step, main.cpp:7444-7460. |
| `L` | "(un)lock screen" (`szH4`) | Toggles `bLocked`, shows "screen is LOCKED"/"unlocked" message (`main.cpp:7286-7301`). |
| `T` | "(un)lock ... palette" (`szH4`) | Toggles `bPalLocked` — **8-bit only**, `FX_Random_Palette` no-ops in 32-bit (`video.h:1393`). |
| `<` `>` (`,` `.`) | "rate screen" (`szH4`) | Increments/decrements `modeprefs[mode]` (0-5), biasing the automatic random mode-switcher toward/away from the current mode. SAVER only. |
| `N` | "new screen (random)" (`szH5`) | Instantly "rushes" the current mode's map generation + resets FPS counter (`main.cpp:7360-7373`). |
| `I` | "shifting on/off" (`szH5`) | Toggles `g_bSlideShift` — a beat-triggered lateral buffer jump-cut pan. |
| `W` | "change waveform" (`szH6`) | Cycles waveform style 0→1→2→3→4→5→6→0 (`main.cpp:7087-7093`). See §2. |
| `P` | "change palette" (`szH6`) | Forces a new random palette — **8-bit only**. |
| bare 2 digits (`##`) | "pick map (01-25)" (`szH7`) | Jumps directly to plasma mode 1-25 (`main.cpp:7553-7580`). |
| `H` / `?` | "toggle help" display (`szH8`) | `SHOW_HELP_MSG` (`main.cpp:7272-7277`). |
| `F` | "toggle fps" display (`szH8`) | `SHOW_FPS` (`main.cpp:7420-7424`). |
| `Z` `X` `C` `V` `B` (SAVER) | "play pause stop" for CD (`szH9`) | Media transport; not applicable to this port. |
| `Z` `X` `C` `V` `B` `R` `S` (PLUGIN) | same + "repeat shuffle" for Winamp (`szH9`) | Not applicable — GeissMac is player-agnostic. |
| `ESC` / click | "quit" (`szH10`) | In GeissMac: ESC cancels an in-progress mode-digit entry first, quits only if nothing pending. |
| `[` / `]` + 2 digits | *(not in help text)* load/save numbered preset | `LoadPreset`/`SavePreset` (`Effects.h:60,132`), `main.cpp:7410-7418`. Restores position, mode, waveform, damping, effect flags, 8-bit palette curve ids. |
| `M` + 2 digits | *(not in help text)* load custom message | Reads `[CUSTOM MESSAGES]` section of `GEISS.INI` (`LoadCustomMsg`, `Effects.h:39`), shown as a tooltip overlay (`main.cpp:7492-7526`). |

## 2. Waveform styles (cycled with `W`)

Source: `RenderWave` (`main.cpp:8646`), dispatched by `waveform` value.
`NUM_WAVES=6` (the live definition, `main.cpp:952` — `DEFINES.H`'s copy is
dead/unused, never `#include`d).

Names: the source never names the styles, except style 6 in its changelog
("added a new waveform (oscilloscope X-Y mode)", main.cpp:96). GeissMac's
on-screen names (`Input/DisplayNames.swift`) are otherwise its own: 1
oscilloscope, 2 dual oscilloscope, 3 vertical oscilloscope, 4 dual
diagonal, 5 circle, 6 X-Y oscilloscope.

| # | Description | main.cpp |
|---|---|---|
| 0 | Off — nothing drawn. | — |
| 1 | Horizontal oscilloscope, full width, single (left) channel. | 9144-9190 |
| 2 | Dual-channel horizontal — L and R each drawn as their own offset line. | 9191-9233 |
| 3 | Vertical oscilloscope (90°-rotated type 1), single channel. | 9234-9256 |
| 4 | Dual-channel diagonal — L and R each as a 45° line running down-right from the top edge, the second shifted right by `FXW-FXH` (`xL = sample + row`, `xR = sample + row + (FXW-FXH)`). Not a rotated type 2, as first assumed. | 9257-9297 |
| 5 | Radial/circular — polar plot, amplitude modulates radius around a ring. | 9298-9335 |
| 6 | Vectorscope/Lissajous — plots L against R directly (not against time), slowly rotated. | 9336-9369 |
| *(7)* | A 7th type exists in source (rotating brightness-modulated beam) but is **unreachable** — both the `W` cycle (`%(NUM_WAVES+1)`) and the automatic random picker only ever produce 0-6. Dead code, not ported. | 9370-9479 |

## 3. Plasma "map" modes (25 total, selected by bare 2-digit entry)

Source: per-mode init (`main.cpp:4386-4566`) and per-pixel scale formulas
(`main.cpp:4677-4876`) inside `GenerateChunkOfNewMap`. The "Name/description"
column quotes the original's own comments verbatim where one exists;
`(no name in source)` means the mode has no descriptive comment at all —
only the formula.

| # | Name/description (quoted from source) |
|---|---|
| 1 | `// ***` — a star-quality rating only, no descriptive name. Fixed zoom+rotate, no per-pixel formula. |
| 2 | `// ****` — same, fixed zoom+rotate, slightly faster. |
| 3 | "terra-landing new_mode" |
| 4 | "normal mode 4 sphere:" |
| 5 | "***** SUPER-perspective" — the highest star rating in the whole switch. |
| 6 | "VORTEX THINGY" |
| 7 | "fuzzy" |
| 8 | "ripples" |
| 9 | "crazy-ass feedback (flower petals in 320)" — note: the actual petal/angle modulation is commented out in the shipped per-pixel code (`main.cpp:4768-4771`), so despite the name this mode has no real petal math. |
| 10 | *(no name in source)* |
| 11 | *(no name in source)* |
| 12 | "sideways splitter - custom vectors!" |
| 13 | "AWESOME continuous black hole — sucks in @ center, pushes out @ edges, SUPER SMOOTH!!!!!!!" |
| 14 | "the AWESOME up-down split-world warp" |
| 15 | *(no name comment; parameter comments reference "number of petals")* — the mode that actually does have real `atan2`-based petal modulation. |
| 16 | "the crystal ball effect: UNDER CONSTRUCTION" |
| 17 | "mode 1: horz. tunnel" *(old-numbering comment)* |
| 18 | "mode 2: vert. tunnel" *(old-numbering comment)* |
| 19 | "mode 5: vortex (old mode 12)" *(old-numbering comment)* |
| 20 | "mode 7: terra''" *(old-numbering comment)* |
| 21 | "regular zoom-in but w/diced cube look (gritty, dirty electronics; shakes;)" |
| 22 | "***AWESOME*** - phonic rings - scale is dicey based on r" |
| 23 | "BADASS derivative of phonic rings - quicker response & fadeout!" |
| 24 | "mode 11: fast swirl, looks very good" *(old-numbering comment — unrelated to current mode 11)* |
| 25 | "WOW: 1/r scaling... VERY good zoom, and fully speed-scalable (no curl!)" |

## 4. Overlay "glow" effects (independent of the plasma mode)

Source: `Effects.h`, dispatched `main.cpp:5489-5538`, toggled
`main.cpp:7083-7118`. Normally auto-managed per plasma mode via
`effect_freq[]` tables, not manually — the keys let you force them.

| Effect | Key | Effects.h | Mechanism |
|---|---|---|---|
| SHADE | `E` | `ShadeBobs`, 191 | Glowing blob(s) orbiting center on a 2-frequency Lissajous path; additive-brightens center+4-neighbor pixels; per-channel strobe in 32-bit. |
| CHASERS | `Q` | `Two_Chasers`, 604 | 1-2 Lissajous-orbiting points; darkens pixels toward white — a fading light trail. |
| BAR | `U` | `Solid_Line`, 551 | A line traced along a slow Lissajous path; in 32-bit, drawn 3× at phase-offset positions into separate R/G/B channels → chromatic-aberration fringe. |
| DOTS | `D` | `One_Dotty_Chaser`, 784 | Single Lissajous-walking point with a 20-frame trail buffer, each trail dot's RGB independently time-cycled. |
| NUCLIDE | `A` | `Nuclide`, 669 | Only fires when audio is silent; spawns a 3-7-node glowing "atom" around center. |
| GRID | `G` | `Grid`, 947 | Scrolling pulsing grid lines; grayscale only, forces BAR off when active. |
| SOLAR | `Y` | `Drop_Solar_Particles[_320]`, 323/439 | Glowing particles dropped near center, additive brightening with distance falloff and random per-particle RGB. |
| SPECTRAL | *(none)* | dead/deprecated (`main.cpp:1195`: "was the freq. spectrum dots; deprecated") | Not applicable. |

## 5. Color mechanism (32-bit/truecolor mode only)

Source: `main.cpp:8905-9017`, inside `RenderWave`. Gate: `iDispBits>8`.

- **Default** (`g_bSyncColorToSound==false`, `main.cpp:8955-9016`): a pure
  time-based oscillator — each of R/G/B independently driven by its own
  sin/cos pair with per-run-random frequencies (`gF[0..5]`,
  `main.cpp:3978`), producing a smooth endless hue drift, not
  audio-reactive. **GeissMac's default** (`C` = drift).
- **Optional** (`g_bSyncColorToSound==true`, `main.cpp:8907-8954`):
  frequency-band-to-color — bass/mid/treble FFT energy sums mapped to R/G/B,
  blended 97/3 with the same time-oscillator. Toggled only via a dialog
  checkbox (`IDC_WAVECOLOR`) — **no hotkey exists for it in the original**.
  Ported 2026-09-25 as the second step of GeissMac's `C` key.

The `R,G,B,+/-` keyboard color controls mentioned in a `main.cpp:444`
comment block are a wishlist item that was **never implemented** — no such
key cases exist anywhere in the original's input handling.
