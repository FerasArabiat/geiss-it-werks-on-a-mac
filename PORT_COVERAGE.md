# GeissMac — Port Coverage

What's actually built in GeissMac (Swift/Metal source in `Sources/GeissMac/`)
against the original's feature set cataloged in `ORIGINAL_FEATURE_REFERENCE.md`.
Status values: **Ported**, **Partial**, **Not ported**, **Out of scope**
(deliberately not applicable to this port, not a gap).

## Core rendering & audio pipeline

| Original piece | Status | Where | Notes |
|---|---|---|---|
| DirectDraw/proc_map.cpp CPU rasterizer | **Ported** (reimplemented) | `Renderer/Shaders.metal`, `MetalRenderer.swift` | Not a literal port — GPU shaders evaluate each mode's transform analytically per frame instead of precomputing a byte-packed offset/weight table. |
| DirectSound capture (`SOUND.CPP`) | **Ported** (reimplemented) | `Audio/AudioCaptureEngine.swift`, `Audio/SystemAudioTap.swift` | A Core Audio process tap in the packaged app ("System Audio Recording Only" permission), ScreenCaptureKit under `swift run` or as fallback — instead of a DirectSound loopback device. |
| FFT / frequency analysis | **Ported** (reimplemented) | `Audio/FFTAnalyzer.swift` | vDSP-based, not the original's hand-rolled FFT. |
| Beat detection | **Ported** (reimplemented) | `Audio/BeatDetector.swift` | A fresh rolling-mean/variance detector, not a port — the original's own changelog calls its detector mediocre. |
| 8-bit `CrankPal`/`FX_Random_Palette` palette curves | **Ported as an option** (2026-09-25, user request) | `Renderer/EightBitPalette.swift`, `present_fragment` | `FX_Random_Palette` is gated `if (iDispBits != 8) return`, so the truecolor port doesn't use it; `B` turns on the 8-bit look: everything draws in gray (`r = g = b = base`, as the 8-bit branch did) and the present pass looks the brightest channel up in a 256-color palette. Palettes rolled as the original did (1 in 6 one of the 4 fixed "FX" palettes, else 3 random CrankPal curves 1-6, curve 7 in a fifth, at most one "really dark" curve 6; a doubled "coarse" band in 1 in 10; 30% brighter in silence), new on every mode switch unless locked, crossfaded over 9 frames (PutPalette), saved in presets. |
| Gamma control (`gamma` slider) | **Out of scope** | — | Only consumed by the 8-bit palette curve generator; the 8-bit look uses its default (0) plus the silence boost. |

## Plasma modes (see `ORIGINAL_FEATURE_REFERENCE.md` §3 for names)

**All 25 ported and user-confirmed working.** Two known issues explicitly
parked by the user for a later pass (not forgotten, not silently accepted):

| Mode | Status | Notes |
|---|---|---|
| 1-5, 8-10, 13-25 | **Ported**, confirmed working | |
| 6 (VORTEX THINGY) | **Ported** — restored to the original's full vortex force (2026-09-25); random vortex layout per visit. The user's earlier tuning lives on as mode 26. |
| 7 (fuzzy) | **Ported** (substitute) | Per-pixel grain uses a deterministic hash, not the original's exact 2345-entry `rand()` table — that RNG state isn't reproducible. Same visual character, different exact values. |
| 12 (sideways splitter) | **Ported** — revisited 2026-09-25: with the original's half-speed damping it reads as its source comment says, "horizontal streaking, out from centerline"; the earlier "very wrong" look was it running at 2x speed. |
| 26 (smooth vortex) | **New, not in original** — mode 6 with half the vortex pull, the tuning the user chose earlier; otherwise behaves as mode 6 (`Modes.original`). Neutral 3-star rating. |

**Automatic mode switching — Ported (2026-09-25)**: a new random mode every
~18s (550 frames at 30fps), synced to the next beat when music plays; each
switch, manual or automatic, also randomizes the waveform style and zoom
center and re-rolls effects (`InputController.tick` / `switchModeLocked`).
**Per-visit motion randomization — Ported (2026-09-25)**: every switch
re-rolls the mode's rotation, scales and f1–f3 from the original's ranges
(random direction, `*0.6`), mode 6's five vortex points, mode 5's
NUCLIDE-dependent falloff, and the per-mode `mode_motion_dampened` damping
(0.5 for modes 1, 2, 4, 5, 7–16) — see `Renderer/ModeMotion.swift`. Trail
fade is the original's exact blend (weightsum 253, mode 12 247, rounded down) since 2026-09-25.

Mode-select input: **Ported** — the original's real two-digit scheme
(`InputController.swift`), not a redesign.

## Waveform (see `ORIGINAL_FEATURE_REFERENCE.md` §2)

| Style | Status |
|---|---|
| 0 (off), 1-6 | **Ported**, confirmed working before the 2026-09-25 rework — re-test pending. Now: pixel-space, 1 original px thick, centered on the mouse-driven center; the original's per-style audio slice (~7ms) and along-the-line smoothing; per-style amplitudes; radial/vectorscope true circles; style 4 is the original's two 45° diagonals. |
| 7 (unreachable in original) | **Out of scope** — dead code in the original itself. |
| Injected brightness scaled by actual RMS loudness | **New, not in original** | The original's waveform draw brightness was fixed; only geometry came from the signal. |

## Color (see `ORIGINAL_FEATURE_REFERENCE.md` §5)

| Piece | Status |
|---|---|
| Default time-oscillator hue cycle | **Ported** — `Renderer/SceneColor.swift`'s `SceneColor.time`, formula verified against `main.cpp:8955-9016`. Its clock (`intframe*30/fps`) is kept in real time by `InputController`, shared by every screen. |
| "Sync color to sound" (FFT-band → RGB) | **Ported** (2026-09-25, user request) — `SceneColor.sound` + `SoundBands`: the original's 23 log-spaced single-bin DFTs over the latest 256 samples (same window duration at the capture rate), smoothed 0.94/0.06 per original frame, summed into red (bass) / green (mids) / blue (treble), weighted ×0.93/×1.18/×2.40, red −0.4·blue, normalized, mixed 97/3 with the old 0.3/0.2 time color ×1.35 (`main.cpp:8273-8289, 8907-8954`). A setup-dialog option in the original; here the `C` key. Test tones: 60-120 Hz red, 250-500 Hz green, 1 kHz+ blue. |
| Color lock / new color | **New, not in original** (user request) — `C` cycles drift → sync to sound → locked (the drift clock frozen; brightness still follows loudness and beats). `P` jumps the drift clock to a random point with a clearly different hue (the original's `P` did this for the 8-bit palette); in sound mode it only shows a hint. |
| `R,G,B,+/-` manual color keys | **Out of scope** | Confirmed never implemented in the original — wishlist-only comment, no actual key handling exists. |

## Overlay "glow" effects (see `ORIGINAL_FEATURE_REFERENCE.md` §4)

| Effect | Status | Notes |
|---|---|---|
| SOLAR | **Ported**, awaiting user test | `Drop_Solar_Particles` — scattered sparks around the mouse-driven center. Shares `sceneColor` with the waveform (deliberate deviation — the original's per-channel random colors read as "cycling RGB"). 2026-09-25: spark size matched to the original's 3x3 stamp at `nativePixelScale`; per-mode `solar_max` ported (0-800). Sparks now linger and grow as in the original since the port uses its exact fade (2026-09-25). Mode 1's 500-particle entry burst is ported. |
| SHADE | **Ported**, awaiting user test | `ShadeBobs` — 2026-09-25: constants corrected to the original's real ranges (1 blob, radius 2.0-4.8 original px, fast orbit, 4 random-walked "+" stamps per frame); previously 2 large slow-orbiting blobs from invented constants. Brightness pulse instead of the original's per-channel hue strobe (shared palette). |
| Mouse-driven center (`gXC`/`gYC`) | **Ported** (2026-09-25) | `WM_MOUSEMOVE` → center clamped to ±40/±30 original px, scaled; drives warp, waveform, SOLAR, SHADE. User-confirmed. |
| `Diminish_Center` (per-mode `center_dwindle`) | **Ported** (2026-09-25) | In `warp_fragment`. Dims a 5-px "+" at the center each frame; a vertical line in mode 12 (0.915). |
| CHASERS | **Ported** (2026-09-25), awaiting user test | `Two_Chasers` — 1-2 white points racing Lissajous paths, screen-blended toward white. `Q`. |
| BAR | **Ported** (2026-09-25), awaiting user test | `Solid_Line` ×3 — short line near the center, one per color channel at phase-shifted positions (chromatic fringes). `U`. |
| DOTS | **Ported** (2026-09-25), awaiting user test | `One_Dotty_Chaser` — 20-dot colored trail, overwritten each frame, drifting right. `D`. |
| NUCLIDE | **Ported** (2026-09-25), awaiting user test | `Nuclide` — ring of 3-7 glowing "atoms", only after ~37s of silence (the original's `SoundEmpty`). `A`. |
| GRID | **Ported** (2026-09-25), awaiting user test | `Grid` — screen-anchored lattice of pulsing gray pixels scrolling sideways. `G`. |

All seven live in `Renderer/OverlayEffects.swift`, drawn in the original's
order, each with a blend pipeline matching its pixel math (add / screen /
replace / max).

**Per-mode automatic effect toggling — Ported (2026-09-25).** Every mode
selection (and launch) re-rolls all seven from the original's per-mode
`effect_freq` odds with its 32-bit adjustments, ×0.7 while sound plays,
clipped to the mode's min/max effect counts, GRID forcing BAR off — see
`InputController.rollEffects`. The keys still toggle effects until the next
mode switch, as in the original.

## Keyboard controls (see `ORIGINAL_FEATURE_REFERENCE.md` §1)

| Key(s) | Status |
|---|---|
| Bare 2-digit mode select | **Ported** |
| `W` waveform cycle | **Ported** |
| `Y` `E` `Q` `U` `D` `A` `G` (overlay effect toggles) | **Ported** — all seven. |
| `T` clock mode | **New, not in original** (user request) — the time (Mac's 12/24-hour setting) pops up like the song title — overlay, then stamped into the trails — when turned on and every 10 seconds after. The original's `T` locked the 8-bit palette (not applicable). |
| `M` mouse steering on/off | **New, not in original** (user request) — the original's `M` began custom-message entry, not ported. The mouse still nudges the center only within ±40/±30 original px, as in the original. |
| `S` frame-rate mode | **New, not in original** — `S` was Winamp shuffle (not applicable). Cycles 30fps → 60fps fast (every per-frame step doubled — not the original's behavior) → 60fps smooth (classic speed; **the default** since 2026-09-25, user's choice). |
| Escape (quit / cancel pending entry) | **Ported** (app-appropriate reinterpretation — see `REQUIREMENTS.md` on why the original's screensaver-exit convention doesn't apply here) |
| `T` (palette lock) | **Moved to `C`** — no-op in 32-bit in the original; in the 8-bit look `C` toggles the palette lock with the original's messages. `T` is the port's clock. |
| `P` (random palette) | **Ported** (2026-09-25) — in the 8-bit look, a new random palette (also while locked, keeping the lock — the original ignored `P` when locked); in truecolor, a new random color, see Color above. |
| `B` 8-bit look | **New key** (2026-09-25) — `B` was CD "next"; turns the 8-bit look on/off, see the palette row above. |
| `C` color mode | **New key** (2026-09-25) — `C` was CD play; cycles drift / sync to sound / locked, see Color above. |
| `J` `K` (wave gain) | **Ported** (2026-09-25) — wave height in the original's `volpos` steps (×0.8 / ×1.25, ±10); title shows "wave gain ±N". |
| `L` (screen lock) | **Ported** (2026-09-25) — stops automatic switching (pauses the countdown); cleared by any mode switch, as in the original. Title shows "(locked)". |
| `<` `>` (mode preference rating) | **Ported** (2026-09-25) — `Input/ModeRatings.swift`: 0-5 stars per mode, the original's defaults (modes 5-9 at 5, 17 at 4, 15 at 2, 12 at 1, rest 3; Sysstuff.h:375-380), persisted as JSON in Application Support; the automatic picker is weighted by them, as the original's was. HUD shows "mode 05: name [*****] (5 stars)"; help shows the current mode's rating. |
| `N` (rush map generation) | **Ported** (2026-09-25) — switches to a new random mode immediately (the effect of "rushing" the pending map). |
| `I` (slide-shift toggle) | **Ported** (2026-09-25) — on beats the whole image starts drifting by 0-2 original px sideways (reversing) and -1/0/+1 vertically until the next beat; also rolled on for 33% of mode switches. Title shows "shift". |
| `H`/`?`/`F` (help/FPS overlay toggles) | **Ported** (2026-09-25) — see the HUD row below. Help lists this port's actual keys in the original's style. |
| `[`/`]` + digits (preset load/save) | **Ported** (2026-09-25) — `[##` loads, `]##` saves; see the row below. |
| `V` new variant | **New, not in original** (user request) — re-rolls the current mode's motion only (keeps waveform, effects, center), restarts the auto-switch clock, shows "mode NN: name — variant N". Modes 10, 12, 24 have no randomized parameters. `V` was CD/Winamp "stop" (not applicable). |
| `M` + digits (custom messages) | **Not ported** | The messages lived in `GEISS.INI` and showed via the Winamp song-title popup; needs a config file this port doesn't have. |
| `O` (sound on/off) | **Ported** (2026-09-25) — stops/restarts audio capture (tap or ScreenCaptureKit, clearing macOS's recording indicator); with sound off the wave goes quiet and NUCLIDE becomes eligible, as in the original. Title shows "sound off". |
| CD/media transport, Winamp shuffle/repeat | **Out of scope** | Player-specific; GeissMac is player-agnostic by design (see `REQUIREMENTS.md`). |

## Other original systems

| System | Status |
|---|---|
| On-screen HUD text | **Ported** (2026-09-25) — `Renderer/HUDOverlay.swift`: the original's system-font lines on black boxes at the top-left (one message by priority, plus the help block), drawn over the final image. At the user's request: white regular-weight text with no background box (soft shadow for legibility) instead of the original's yellow on black, at 0.48× the original's 640-wide proportions. Messages: screen locked/unlocked, frame-rate mode, two-digit mode entry plus a 3s "mode NN: name — description" confirmation after digits or `N` (port additions — fullscreen has no title bar; names from the original's source comments, `Input/ModeNames.swift`), FPS. Help (user request): controls at the top-left and effects at the top-right, each row with its live state and dimmed when off; waveform styles shown by name (`Input/DisplayNames.swift` — only style 6 is named in the original, in its changelog). Custom messages not applicable. |
| Song title popup (plug-in's SPACE + title change) | **Ported** (2026-09-25) — `Audio/TrackWatcher.swift`, `SongTitlePopup`: the current track from macOS Now Playing (via `Sources/NowPlayingHelper` run in /usr/bin/perl — private API, fine outside the App Store). The AppleScript fallback was removed at the user's request (2026-09-25). Shown as the original did: bold title, white over a dark shadow at a random center-biased spot, then stamped into the trails in a random light color to melt away. 2s instead of the original's 20-frame default (its slider allowed 2-100). |
| Numbered preset save/load (`GEISS.INI`) | **Ported** (2026-09-25) — `Input/Presets.swift`: presets 00-99 as JSON in `~/Library/Application Support/GeissMac/presets.json`, storing mode, the visit's rolled motion (incl. mode 6's vortex points), waveform, center, effects, slide shift, wave gain and the 8-bit palette (applied unless locked, as the original's `FX_Random_Palette(true)`). Loading applies like any switch, so auto-switching resumes unless `L`. |
| Per-mode automatic effect toggling (`effect_freq[]` tables) | **Ported** (2026-09-25) | See the overlay section above. |
| `rotation_dither`/`custom_motion_vectors`/`mode_motion_dampened` mode-feel tables | **Ported** | Modes 6/10/12 custom motion vectors; `rotation_dither` for 9 (formula vs. constant scale2 on a checkerboard — earlier wrongly assumed a no-op) and 11; `mode_motion_dampened` via ModeMotion (2026-09-25). The port's beat-driven damping kick still multiplies on top — a deliberate addition (the original's audio-driven damping is disabled in its source). |
| Multi-monitor (pick one monitor to run on) | **Superseded** | GeissMac runs on every connected screen simultaneously instead — see `REQUIREMENTS.md`. |
| Winamp plug-in target | **Out of scope** | See `REQUIREMENTS.md`. |
