# Geiss It Werks on a Mac — Requirements

"Geiss It Werks on a Mac" (the app's name since 2026-09-25, bundle id
`com.ferasarabiat.GeissItWerksOnaMac`; the code and Swift package are still
GeissMac) is a modern macOS reimplementation of Ryan Geiss's Geiss
visualizer (originally a Windows screensaver + Winamp plug-in, source in
`original/`). This is a from-scratch native app that reuses Geiss's *visual and audio
algorithms* as a design spec — none of the original Win32/DirectX/asm code is
carried over as-is.

Two companion reference documents, both extracted directly from the
original's source (not paraphrased from general knowledge of "Geiss"):

- **`ORIGINAL_FEATURE_REFERENCE.md`** — every keyboard control, waveform
  style, plasma mode (with the original's own names/comments, quoted), and
  overlay effect that exists in the original, with file:line citations.
- **`PORT_COVERAGE.md`** — the same catalog cross-referenced against what's
  actually built in GeissMac so far, so scope is visible at a glance.

## Decisions already made (don't relitigate without a reason)

- **Not a screensaver.** No `.saver`/ScreenSaverKit bundle. It's a regular
  fullscreen app that the user launches by hand — no auto-launch when the
  Mac is idle (the user's call, 2026-09-25). Reason: the system screensaver host
  unconditionally exits on any keyboard/mouse input, which conflicts with
  Geiss's original design of using mouse movement and keys to control effects
  without exiting. Owning our own event loop makes that interactivity
  straightforward instead of requiring a workaround.
- **Apple Silicon only, modern macOS only.** Target `macOS 14+` (Sonoma),
  arm64 only. No Intel, no legacy-OS fallbacks, no OpenGL. This lets the
  renderer be designed around Metal/GPU shaders from the start instead of
  porting the original CPU MMX/Cyrix asm loops line-by-line.
- **Rendering:** GPU-based (Metal), reimplementing each of Geiss's "modes"
  (see `Effects.h` / `proc_map.cpp` in `original/`) as fragment/compute shaders
  driven by audio + input state, rather than a faithful port of the original
  CPU rasterizer.
- **Audio capture:** in the packaged app, a Core Audio process tap
  (`CATapDescription` + private aggregate device, macOS 14.4+) — it needs
  only the "System Audio Recording Only" permission, requested through the
  Info.plist's `NSAudioCaptureUsageDescription`. ScreenCaptureKit's audio
  path (`SCStream`, `capturesAudio`) remains the fallback and the `swift run`
  path (no Info.plist); it needs Screen Recording permission and, on macOS
  15+, brings a recurring "bypass the private window picker" prompt — the
  reason for the switch (2026-09-25). Both avoid requiring a virtual audio
  device like BlackHole.
- **Distribution (2026-09-25):** a zipped `.app` attached to GitHub
  Releases (`scripts/build-app.sh` makes both). No App Store — so the Now
  Playing helper's private API is fine, and there's no sandbox. Releases
  are signed with a Developer ID and notarized:
  `build-app.sh --notarize`, hardened runtime with the audio-input
  entitlement (`Resources/GeissMac.entitlements`). One-time setup in
  README.md › Releasing.
- **Song title:** from macOS Now Playing only (the perl-hosted helper). The
  AppleScript fallback that asked players and browsers was removed at the
  user's request (2026-09-25); if Now Playing breaks, there's no title.
- **Multi-monitor:** one fullscreen window + renderer per connected `NSScreen`,
  all active simultaneously (original Geiss let you pick *one* monitor to run
  on; we don't need that restriction here).

## Functional requirements

1. Launches as a normal macOS app; goes fullscreen (borderless, one window
   per screen, Dock and menu bar hidden, cursor hidden) on start.
2. Renders GPU-accelerated visual effects reacting to live system audio:
   waveform/oscilloscope-style modes, spectrum-driven coloring, beat-reactive
   brightness/mode-switching (mirroring Geiss's v4.00 "true beat detection").
3. Keyboard and mouse control effects/mode/palette in real time, without
   exiting the app (mirrors Geiss v4.01: "screensaver no longer exits on
   mouse movement," "some effects can now be controlled by moving the
   mouse"). Escape and Cmd+Q exit. Key bindings follow the original's
   scheme — see README.md and PORT_COVERAGE.md.
4. Multiple palette "curves" selectable and lockable — 8-bit-only in the
   original, so not part of the truecolor port; available since 2026-09-25
   as the optional 8-bit look (`B`, with `C` locking and `P` changing the
   palette). The truecolor colors can be locked and changed too.
5. Runs at a steady frame rate — 60fps smooth by default (the original's
   30fps reference speed, rendered at 60 — closest to how the original
   behaved at 60fps); `S` cycles to 30fps and 60fps fast (every per-frame
   step doubled — not the original's behavior, kept as an option) —
   scaling to at least one 4K/5K Retina display per window.

## Non-functional requirements

- No dependency on Rosetta 2 or any x86_64 binary/framework.
- No installer, registry, or `.ini`-style config file — presets and mode
  ratings are small JSON files in `~/Library/Application Support/GeissMac/`.
- Preserve attribution: original code is 3-clause BSD, © Ryan Geiss. Keep
  `LICENSE` and credit him in this project's README/about screen.
- Distributed outside the App Store (GitHub Releases), unsandboxed.

## Explicitly out of scope

- Winamp plug-in target (the original ships both a screensaver and a Winamp
  vis plug-in; this port is player-agnostic system-audio capture instead).
- 8-bit/16-bit rendering (original supported multiple color depths for
  1998-era hardware). The 8-bit *look* is emulated on the truecolor
  pipeline as an option; 16-bit isn't.
- Any screensaver-host integration (System Settings > Screen Saver panel).
- Windows/cross-platform support of any kind.

## Open questions

None open. Settled since first written: distribution (GitHub Releases)
and idle-launch (none) — see Decisions above; key bindings follow the
original's scheme (two-digit modes, `[##`/`]##` presets, the original's letter keys, plus a few
port additions — see PORT_COVERAGE.md); presets are the original's numbered
00-99 slots, stored as JSON instead of GEISS.INI.

## Current status

Feature-complete as a port of the original screensaver. `PORT_COVERAGE.md`
is the authoritative itemized breakdown; summary:

- **All 25 plasma modes**, with the original's per-visit motion
  randomization and per-mode damping, plus one port-own mode (26 "smooth
  vortex"). `V` rolls a new variant of the current mode.
- **Automatic mode switching** every ~18s, beat-synced, weighted by 0-5 star
  ratings (`<`/`>`, the original's defaults); `L` locks, `N` switches now.
- **All 6 waveform styles** with the original's audio slice and smoothing,
  and its time-based color cycling; `C` switches to the original's "sync
  color to sound" or locks the color, `P` picks a new one, `B` the 8-bit
  look with the original's random palettes.
- **All 7 overlay effects** (SOLAR, SHADE, CHASERS, BAR, DOTS, NUCLIDE,
  GRID), re-rolled per mode from the original's odds, each toggleable.
- **Every element scaled to the original's 640-wide proportions** on modern
  high-resolution displays; the zoom center follows the mouse as it did.
- **Frame rate:** 60fps smooth by default (the original's speed, rendered
  smoother), `S` cycles 30 / 60 fast / 60 smooth.
- **Controls and on-screen text:** the original's keys (effects, wave gain,
  slide shift, sound on/off, presets, ratings), an on-screen help showing
  every toggle's state, fps display, mode names on manual switches.
- **Audio:** a Core Audio process tap in the packaged app ("System Audio
  Recording Only" permission, verified on first launch), ScreenCaptureKit
  under `swift run`; vDSP FFT and beat detection.
- **Packaging:** `scripts/build-app.sh` → a double-clickable, signed
  `Geiss It Werks on a Mac.app` plus its release zip, which runs fullscreen on every display (Escape / ⌘Q quit,
  cursor hidden as in the original).

Not ported: the original's `M` custom messages (they came from GEISS.INI)
and the Winamp/CD player keys (the port is player-agnostic).

