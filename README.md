# Geiss It Werks on a Mac

[Geiss](https://www.geisswerks.com/geiss/), Ryan M. Geiss's classic music
visualizer for Windows, rebuilt as a native app for Apple Silicon Macs. It
fills your screens with the feedback-zoom plasma, waveforms and glowing
effects Geiss is known for, reacting live to whatever your Mac is playing.

## Credits

**Geiss is the work of Ryan M. Geiss — [Geisswerks](https://www.geisswerks.com/).**
Its effects, modes, look and name are his. This app is an unofficial port
and isn't affiliated with or endorsed by him; its name is a nod to
Geisswerks.

The port is a new Metal implementation, not a compile of the Windows
code, but it was written from his source and follows it closely — the 25
modes, the waveforms, the overlay effects, the keys and the timing —
scaled to today's high-resolution displays.

- [Geiss home page](https://www.geisswerks.com/geiss/) and
  [How 'Geiss' Worked](https://www.geisswerks.com/geiss/secrets.html)
- The original source, published at
  [github.com/geissomatik/geiss](https://github.com/geissomatik/geiss), is
  included unchanged in [`original/`](original/) under Ryan Geiss's
  BSD 3-Clause license ([LICENSE](LICENSE)).

## Download and run

Requires macOS 14 (Sonoma) or later on Apple Silicon.

Download the zip from the GitHub Releases page, unzip it, and open
**Geiss It Werks on a Mac**. It runs fullscreen on every display until you
press `Esc`. On first launch macOS asks for **System Audio Recording**
permission — that's how it hears the music. It doesn't start by itself
when the Mac is idle; open it whenever you want it.

Releases are notarized by Apple, so macOS opens them normally.

## Build

Requires Xcode 15+ / Swift 5.10+. The Swift package and its code are
still named GeissMac.

- **App:** `scripts/build-app.sh` builds `build/Geiss It Werks on a Mac.app`
  and a zip of it. Without notarization, macOS refuses to open a
  downloaded copy the first time (System Settings › Privacy & Security ›
  Open Anyway gets past it) — fine for your own Mac, not for a release.
- **Development:** `GEISS_WINDOWED=1 swift run GeissMac` runs in a window.
  From the terminal it captures audio through ScreenCaptureKit, using the
  terminal's Screen Recording permission.

## Keys

| Key | Does |
|---|---|
| two digits, e.g. `0` `5` | jump to a mode (01-26) |
| `N` / `V` / `L` | new random mode / new variant of this mode / lock the mode |
| `W`, `J` / `K` | waveform style, wave height down / up |
| `C` / `P` | color: drift / sync to sound / locked; a new random color |
| `B` | 8-bit look: the original's 256-color palettes (`C` locks the palette, `P` picks a new one) |
| `Q` `E` `U` `G` `D` `A` `Y` | effects: chasers, shade, bar, grid, dots, nuclide, solar |
| `I` / `O` | slide shift / sound on-off |
| `[` + two digits / `]` + two digits | load / save a preset (00-99) |
| `<` / `>` | rate this mode (weights automatic switching) |
| `S` | frame rate: 60 smooth / 30 / 60 fast |
| `space` | show the song title again (it also pops up on every new track) |
| `T` | clock mode: the time pops up the same way every 10 seconds |
| `H` or `?`, `F` | help (shows every toggle's state), fps |
| mouse, `M` | nudges the zoom center (within a small box around the middle, as in the original); `M` turns that on/off |
| `Esc`, `⌘Q` | quit (`Esc` first cancels a half-typed number) |

Modes switch automatically every ~18 seconds, on a beat when music is
playing. The name of the playing track comes from macOS's Now Playing.

## Releasing

`scripts/build-app.sh --notarize` builds the app, signs it with your
Developer ID, has Apple notarize it, staples the ticket and writes the zip
to attach to a GitHub release. One-time setup, needing a paid Apple
Developer account:

1. **Developer ID certificate:** in Xcode › Settings › Accounts, select
   your team, click **Manage Certificates…**, then **+** ›
   **Developer ID Application**. (Only the account holder can create one.)
2. **Notary credentials:** create an app-specific password at
   [account.apple.com](https://account.apple.com) › Sign-In and Security ›
   App-Specific Passwords, then run this in Terminal with your Apple ID and
   the Team ID from developer.apple.com › Membership. It asks for the
   password and keeps it in your keychain; the build script only uses the
   profile name.

   ```bash
   xcrun notarytool store-credentials geiss-notary --apple-id YOUR_APPLE_ID --team-id YOUR_TEAM_ID
   ```

The first run with the new certificate asks for the audio permission once
more — macOS ties it to the app's signature.

## Documentation

- [REQUIREMENTS.md](REQUIREMENTS.md) — scope, decisions, current status
- [PORT_COVERAGE.md](PORT_COVERAGE.md) — every original feature vs. what's built
- [ORIGINAL_FEATURE_REFERENCE.md](ORIGINAL_FEATURE_REFERENCE.md) — the
  original's keys, modes and effects, with references into `original/`
