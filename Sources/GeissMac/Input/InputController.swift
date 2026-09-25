import AppKit

/// Shared across all screens' GeissMTKViews. Replaces main.cpp's WindowProc
/// keyboard/mouse handling (originally around WM_KEYDOWN / WM_MOUSEMOVE /
/// VK_ESCAPE). Because this app owns its own event loop instead of running
/// inside the system screensaver host, there's no OS-level "any input exits"
/// behavior to work around — Escape/Cmd+Q are just app-level choices below,
/// same as Geiss's original ESC-to-cancel-then-ESC-to-exit convention.
///
/// Thread-safety note: NSEvent handlers below run on the main thread, but
/// AudioCaptureEngine delivers `latestAudio` from a background dispatch queue,
/// and MTKView's internal display-link-driven draw(in:) runs on its own thread
/// too — so all state here is lock-guarded rather than plain stored properties.
final class InputController {
    private let lock = NSLock()
    private var _effectState = EffectState()
    private var _latestAudio = AudioAnalysis()
    /// A two-digit entry in progress: a mode number, or a preset number
    /// after '[' (load) / ']' (save) — the original's `ePresetState`.
    private enum EntryKind { case mode, loadPreset, savePreset }
    private var pendingEntry: (kind: EntryKind, digits: [Character])?
    private let presets = PresetStore()
    private let ratings = ModeRatings()
    /// Variants rolled with 'V' since the mode was entered (1 = the entry roll).
    private var variantNumber = 1
    /// Last time audio was above the silence threshold (systemUptime).
    private var lastSoundTime = ProcessInfo.processInfo.systemUptime
    private var lastBeatTime: TimeInterval = 0
    /// When the current mode's auto-switch clock started; shifted forward
    /// by time spent locked, so locking pauses the countdown.
    private var modeStartTime = ProcessInfo.processInfo.systemUptime
    private var lockedAt: TimeInterval = 0
    private var lastShiftTime: TimeInterval = 0
    private var soundOn = true
    /// 'M' — whether moving the mouse steers the zoom center.
    private var mouseSteers = true
    /// Called on the main thread when 'O' toggles sound capture.
    var onSoundToggled: ((Bool) -> Void)?

    // On-screen text state (see hudText()).
    private var showHelp = false
    private var showFPS = false
    private var timedMessage: String?
    private var timedMessageUntil: TimeInterval = 0
    /// Set when audio capture couldn't start (no Screen Recording permission)
    /// until audio actually arrives.
    private var audioBlocked = false
    private var audioBlockedNoticeUntil: TimeInterval = 0

    // Text popups (see TextPopup): the song title (TrackWatcher) and the clock.
    private var currentTrack: String?
    private var songTitle: TextPopup?
    private var clockPopup: TextPopup?
    private var popupCount = 0
    /// 'T' — clock mode: the time pops up like the song title every
    /// `clockInterval` seconds, each one stamped into the trails.
    private var clockEnabled = false
    private var lastClockShownAt: TimeInterval = 0
    private static let clockInterval: TimeInterval = 10

    /// The color clock (EffectState.colorTime): `colorClockBase` frames at
    /// 30fps as of `colorClockSince`, advancing in real time unless the
    /// color is locked — the original's `intframe * 30/fps`.
    private var colorClockBase: Double = 0
    private var colorClockSince = ProcessInfo.processInfo.systemUptime
    private static let clockFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.timeStyle = .short // follows the Mac's 12/24-hour setting
        formatter.dateStyle = .none
        return formatter
    }()

    init() {
        lock.lock(); defer { lock.unlock() }
        switchModeLocked(to: 5)
    }

    var currentEffectState: EffectState {
        lock.lock(); defer { lock.unlock() }
        var state = _effectState
        state.colorTime = Float(colorTimeLocked(at: ProcessInfo.processInfo.systemUptime))
        return state
    }

    private func colorTimeLocked(at now: TimeInterval) -> Double {
        _effectState.colorMode == .locked ? colorClockBase : colorClockBase + (now - colorClockSince) * 30
    }

    /// Restarts the clock from its current reading, so switching to or from
    /// `locked` freezes or resumes the color exactly where it is.
    private func setColorModeLocked(_ mode: ColorMode) {
        let now = ProcessInfo.processInfo.systemUptime
        colorClockBase = colorTimeLocked(at: now)
        colorClockSince = now
        _effectState.colorMode = mode
    }

    /// 'P' — jumps the color clock to a random point whose color is clearly
    /// different from the current one (compared by hue: each color scaled
    /// so its brightest channel is 1).
    private func jumpColorLocked() {
        let now = ProcessInfo.processInfo.systemUptime
        let current = colorTimeLocked(at: now)
        func hue(_ t: Double) -> SIMD3<Float> {
            let c = SceneColor.time(t: Float(t), base: 1)
            return c / max(c.max(), 0.001)
        }
        let currentHue = hue(current)
        var best = current
        var bestDistance: Float = -1
        for _ in 0..<50 {
            let candidate = current + Double.random(in: 300...20_000)
            let d = hue(candidate) - currentHue
            let distance = (d * d).sum().squareRoot()
            if distance > bestDistance {
                best = candidate
                bestDistance = distance
            }
            if distance > 0.5 { break }
        }
        colorClockBase = best
        colorClockSince = now
    }

    var latestAudio: AudioAnalysis {
        get { lock.lock(); defer { lock.unlock() }; return _latestAudio }
        set {
            lock.lock(); defer { lock.unlock() }
            // Buffers already in flight when 'O' stopped capture.
            guard soundOn else { return }
            audioBlocked = false
            _latestAudio = newValue
            if newValue.rms >= 0.002 { lastSoundTime = newValue.timestamp }
            if newValue.beatDetected {
                lastBeatTime = newValue.timestamp
                if _effectState.slideShiftEnabled && newValue.timestamp - lastShiftTime > 0.1 {
                    lastShiftTime = newValue.timestamp
                    rollSlideOffsetLocked()
                }
            }
        }
    }

    /// The original's slide shift (main.cpp:8842-8849): 0-2 original pixels
    /// sideways, reversed if the previous shift pointed forward, plus -1/0/+1
    /// rows. Its trigger is a volume peak during strong-beat music; the
    /// port's beat detector stands in.
    private func rollSlideOffsetLocked() {
        let old = _effectState.slideOffset
        // `slider1` packs x + y*FXW; "old > 0" means down, or level and right.
        let oldPointedForward = old.y > 0 || (old.y == 0 && old.x > 0)
        var dx = Float((Int.random(in: 0..<320) + 50) / 145)
        if oldPointedForward { dx = -dx }
        _effectState.slideOffset = SIMD2(dx, Float(Int.random(in: -1...1)))
    }

    /// The original's `SoundEmpty` (main.cpp:8881-8895): silence lasting
    /// frames_til_auto_switch*2 frames (~37s at its 30fps), or no capture
    /// at all (`!SoundActive`). Buffers that stop arriving count as silence.
    var soundEmpty: Bool {
        lock.lock(); defer { lock.unlock() }
        return soundEmptyLocked
    }

    private var soundEmptyLocked: Bool {
        _latestAudio.waveform.isEmpty || ProcessInfo.processInfo.systemUptime - lastSoundTime > 36.7
    }

    /// Geiss's original mode-select scheme: type two digits (e.g. '0' then
    /// '5' for mode 5) to jump directly to a mode number, matching main.cpp's
    /// documented "press '##' to select a mode directly" convention. All 25
    /// of the original's modes are ported.
    private static let digitKeys: [UInt16: Character] = [
        18: "1", 19: "2", 20: "3", 21: "4", 23: "5",
        22: "6", 26: "7", 28: "8", 25: "9", 29: "0",
    ]

    /// 'W' — cycles waveform draw style, matching main.cpp:7087-7093's
    /// `waveform = (waveform + 1) % (NUM_WAVES+1)` (NUM_WAVES=6, so this
    /// cycles 0 (off) through 6).
    private static let waveformCycleKeyCode: UInt16 = 13

    /// Overlay effect toggles, matching the original's own key assignments
    /// (main.cpp:7083-7118, ORIGINAL_FEATURE_REFERENCE.md §4).
    private static let solarToggleKeyCode: UInt16 = 16   // Y
    private static let shadeToggleKeyCode: UInt16 = 14   // E
    private static let chasersToggleKeyCode: UInt16 = 12 // Q
    private static let barToggleKeyCode: UInt16 = 32     // U
    private static let dotsToggleKeyCode: UInt16 = 2     // D
    private static let nuclideToggleKeyCode: UInt16 = 0  // A
    private static let gridToggleKeyCode: UInt16 = 5     // G

    /// 'S' — cycles 30fps / 60fps fast / 60fps smooth. Not an original key:
    /// every letter is bound in the original, and 'S' was Winamp shuffle,
    /// which doesn't apply here.
    private static let fpsToggleKeyCode: UInt16 = 1

    /// 'L' locks the current mode; 'N' switches to a new random mode now
    /// (the original's "rush the map", main.cpp:7286-7301, 7360-7364).
    private static let lockToggleKeyCode: UInt16 = 37
    private static let newModeKeyCode: UInt16 = 45

    /// 'J'/'K' wave height, 'I' slide shift, 'O' sound on/off
    /// (main.cpp:7444-7460, 7266-7270, 7053-7080).
    private static let waveDownKeyCode: UInt16 = 38
    private static let waveUpKeyCode: UInt16 = 40
    private static let slideShiftKeyCode: UInt16 = 34
    private static let soundToggleKeyCode: UInt16 = 31

    /// '[' + two digits loads a preset, ']' + two digits saves one
    /// (main.cpp:7410-7418 and 6971-7016).
    /// SPACE — show the song title again (the original plug-in's SPACE,
    /// main.cpp:7303-7311).
    private static let songTitleKeyCode: UInt16 = 49

    /// 'T' — clock mode on/off. Not an original key: the original's T locked
    /// the 8-bit palette, which doesn't apply in truecolor.
    private static let clockKeyCode: UInt16 = 17

    /// 'M' — mouse steering on/off. Not an original key: the original's M
    /// began a custom-message entry, which isn't ported (it read GEISS.INI).
    private static let mouseSteeringKeyCode: UInt16 = 46

    /// 'C' — color mode: drift / sync to sound / locked. Not an original key
    /// (C was CD "play"); sound sync was a setup-dialog option there.
    private static let colorModeKeyCode: UInt16 = 8
    /// 'P' — a new random color. The original's P picked a new 8-bit
    /// palette; this is its truecolor counterpart.
    private static let newColorKeyCode: UInt16 = 35
    /// 'B' — the 8-bit look on/off. Not an original key (B was CD "next").
    private static let eightBitKeyCode: UInt16 = 11

    private static let loadPresetKeyCode: UInt16 = 33
    private static let savePresetKeyCode: UInt16 = 30

    /// 'V' — re-roll the current mode's motion (a new variant), keeping
    /// everything else. Not an original key (V was CD/Winamp "stop", which
    /// doesn't apply here); added at the user's request.
    private static let variantKeyCode: UInt16 = 9

    /// '<' / '>' (the ',' / '.' keys) rate the current mode 0-5 stars,
    /// weighting the automatic picker (main.cpp:7382-7407).
    private static let rateDownKeyCode: UInt16 = 43
    private static let rateUpKeyCode: UInt16 = 47

    /// 'H' or '?' (the '/' key) toggles help, 'F' the FPS display
    /// (main.cpp:7272-7277, 7420-7424).
    private static let helpKeyCodes: Set<UInt16> = [4, 44]
    private static let fpsDisplayKeyCode: UInt16 = 3

    /// `SHOW_*_MSG = 30` — 30 frames at the original's 30fps.
    private func showTimedMessageLocked(_ text: String, seconds: TimeInterval = 1) {
        timedMessage = text
        timedMessageUntil = ProcessInfo.processInfo.systemUptime + seconds
    }

    /// Port addition (user request): confirm a manually chosen mode (digits
    /// or 'N') with its name. Automatic switches stay silent, as in the
    /// original. Longer than the original's 1s messages so the name can be read.
    private func showModeConfirmationLocked() {
        let mode = _effectState.mode
        showTimedMessageLocked("mode \(Self.formatMode(mode)): \(ModeNames.label(for: mode))", seconds: 3)
    }

    private func pendingEntryTextLocked() -> String? {
        guard let entry = pendingEntry else { return nil }
        let typed = String(entry.digits) + "_"
        switch entry.kind {
        case .mode: return "mode \(typed)"
        case .loadPreset: return "load preset \(typed)"
        case .savePreset: return "save preset \(typed)"
        }
    }

    private func completeEntryLocked(_ kind: EntryKind, number: Int) {
        let numberText = Self.formatMode(number)
        switch kind {
        case .mode:
            switchModeLocked(to: number)
            showModeConfirmationLocked()
        case .savePreset:
            let saved = presets.save(currentPresetLocked(), as: number)
            showTimedMessageLocked(saved ? "preset \(numberText) saved" : "preset \(numberText) kept for this session (couldn't write file)", seconds: 2)
        case .loadPreset:
            if let preset = presets.preset(number) {
                applyPresetLocked(preset)
                showTimedMessageLocked("preset \(numberText): mode \(Self.formatMode(preset.mode)) \(ModeNames.name(for: preset.mode))", seconds: 3)
            } else {
                showTimedMessageLocked("preset \(numberText) not found", seconds: 2)
            }
        }
    }

    /// A fresh ModeMotion roll for the current mode — what re-entering the
    /// mode would roll, without re-rolling waveform, effects or center.
    /// Restarts the auto-switch clock so the new variant can be watched.
    /// Modes 10, 12 and 24 have nothing randomized in the original.
    private func rollVariantLocked() {
        let mode = _effectState.mode
        let label = "mode \(Self.formatMode(mode)): \(ModeNames.name(for: mode))"
        guard Modes.all.contains(mode), ![10, 12, 24].contains(mode) else {
            showTimedMessageLocked("\(label) has no variants", seconds: 2)
            return
        }
        _effectState.motion = ModeMotion.random(forMode: mode, nuclideWasOn: _effectState.nuclideEnabled)
        variantNumber += 1
        modeStartTime = ProcessInfo.processInfo.systemUptime
        showTimedMessageLocked("\(label) — variant \(variantNumber)", seconds: 2)
    }

    private func currentPresetLocked() -> Preset {
        let s = _effectState
        return Preset(mode: s.mode, motion: s.motion, waveformType: s.waveformType, centerOffset: s.centerOffset,
                      chaserCount: s.chaserCount, barEnabled: s.barEnabled, dotsEnabled: s.dotsEnabled,
                      solarEnabled: s.solarEnabled, gridEnabled: s.gridEnabled, nuclideEnabled: s.nuclideEnabled,
                      shadeEnabled: s.shadeEnabled, slideShiftEnabled: s.slideShiftEnabled, waveScaleStep: s.waveScaleStep,
                      palette: s.palette)
    }

    /// Loading goes through the same apply step as any switch in the
    /// original (GenerateChunkOfNewMap with bLoadPreset, main.cpp:4576-4589,
    /// 5304-5318) with the saved values instead of random ones — so, as
    /// there, the lock clears and auto-switching resumes unless 'L' is hit.
    private func applyPresetLocked(_ p: Preset) {
        _effectState.mode = p.mode
        _effectState.motion = p.motion
        _effectState.waveformType = p.waveformType
        _effectState.centerOffset = p.centerOffset
        _effectState.chaserCount = p.chaserCount
        _effectState.barEnabled = p.barEnabled
        _effectState.dotsEnabled = p.dotsEnabled
        _effectState.solarEnabled = p.solarEnabled
        _effectState.gridEnabled = p.gridEnabled
        _effectState.nuclideEnabled = p.nuclideEnabled
        _effectState.shadeEnabled = p.shadeEnabled
        _effectState.slideShiftEnabled = p.slideShiftEnabled
        _effectState.slideOffset = .zero
        _effectState.waveScaleStep = p.waveScaleStep
        // FX_Random_Palette(true): the saved palette, unless locked.
        if let palette = p.palette, _effectState.colorMode != .locked {
            _effectState.palette = palette
            _effectState.paletteSerial += 1
        }
        _effectState.locked = false
        variantNumber = 1
        _effectState.modeSwitchCount += 1
        modeStartTime = ProcessInfo.processInfo.systemUptime
    }

    private static func formatMode(_ mode: Int) -> String {
        mode < 10 ? "0\(mode)" : "\(mode)"
    }

    /// The original's help (main.cpp:1004-1025, `szH1`-`szH10`) listed the
    /// keys; at the user's request this port's help lists its actual keys
    /// with their current state — controls on the left, effects on the
    /// right side of the screen. The 8-bit palette lock and the CD/Winamp
    /// keys don't apply here; their letters carry the port's additions.
    private func helpLocked() -> (controls: [String], effects: [String]) {
        let s = _effectState
        func onOff(_ on: Bool) -> String { on ? "on" : "off" }
        let gain = s.waveScaleStep == 0 ? "0" : String(format: "%+d", s.waveScaleStep)
        let colorLabel = !s.eightBit ? s.colorMode.label
            : s.colorMode == .locked ? "palette locked" : "new palette each mode"
        let controls = [
            "w  waveform\t\(WaveformNames.name(for: s.waveformType))",
            "b  8-bit look\t\(onOff(s.eightBit))",
            "c  color\t\(colorLabel)",
            s.eightBit ? "p  new palette" : "p  new color",
            "##  pick map (01-26)\t\(Self.formatMode(s.mode)) \(ModeNames.name(for: s.mode))",
            "n  new screen (random)",
            "v  new variant of this mode",
            "< / >  rate this mode\t\(ratings.stars(for: s.mode).map { "\($0) stars" } ?? "-")",
            "[## / ]##  load / save preset",
            "L  lock screen\t\(onOff(s.locked))",
            "i  shifting\t\(onOff(s.slideShiftEnabled))",
            "m  mouse steers center\t\(onOff(mouseSteers))",
            "o  sound\t\(audioBlocked ? "no permission" : onOff(soundOn))",
            "j/k  wave gain\t\(gain)",
            "s  frame rate\t\(s.frameRateMode.label)",
            "space  show song title",
            "t  clock\t\(onOff(clockEnabled))",
            "h/f  help / fps display",
            "ESC  quit",
        ]
        let effects = [
            "q  chasers\t\(onOff(s.chaserCount > 0))",
            "e  shade\t\(onOff(s.shadeEnabled))",
            "u  bar\t\(onOff(s.barEnabled))",
            "g  grid\t\(onOff(s.gridEnabled))",
            "d  dots\t\(onOff(s.dotsEnabled))",
            "a  nuclide (in silence)\t\(onOff(s.nuclideEnabled))",
            "y  solar\t\(onOff(s.solarEnabled))",
        ]
        return (controls, effects)
    }

    /// A new track from TrackWatcher — the original popped the title on
    /// every change (video.h:96-105).
    func trackChanged(_ track: String) {
        lock.lock(); defer { lock.unlock() }
        currentTrack = track
        showSongTitleLocked()
    }

    private func showSongTitleLocked() {
        guard let track = currentTrack else {
            showTimedMessageLocked("no song title yet", seconds: 2)
            return
        }
        songTitle = makePopupLocked(track)
    }

    /// Port addition (user request): the time, shown like the song title.
    private func showClockLocked() {
        lastClockShownAt = ProcessInfo.processInfo.systemUptime
        clockPopup = makePopupLocked(Self.clockFormatter.string(from: Date()))
    }

    /// Random light stamp color (`128 + rand()%99` per channel) and a
    /// center-biased spot (four quarter-range randoms summed, video.h:185-195).
    private func makePopupLocked(_ text: String) -> TextPopup {
        func channel() -> Float { Float(128 + Int.random(in: 0..<99)) / 255 }
        func centerBiased() -> Float { (0..<4).map { _ in Float.random(in: 0..<0.25) }.reduce(0, +) }
        popupCount += 1
        return TextPopup(id: popupCount, text: text,
                         stampColor: SIMD4(channel(), channel(), channel(), 1),
                         position: SIMD2(centerBiased(), centerBiased()),
                         shownAt: ProcessInfo.processInfo.systemUptime)
    }


    /// Port addition: without Screen Recording permission the visuals run
    /// with no audio and nothing on screen said why.
    func audioCaptureFailed() {
        lock.lock(); defer { lock.unlock() }
        audioBlocked = true
        audioBlockedNoticeUntil = ProcessInfo.processInfo.systemUptime + 20
    }

    /// The original shows one message line at a time, by priority (main.cpp:
    /// 2046-2084: locked > unlocked > misc > ... > fps), plus the help block.
    /// Mode-digit entry comes first here — the original showed nothing while
    /// typing, but in fullscreen there's no window title to show it in.
    func hudText() -> HUDText {
        lock.lock(); defer { lock.unlock() }
        var message: String?
        if let entry = pendingEntryTextLocked() {
            message = entry
        } else if ProcessInfo.processInfo.systemUptime < timedMessageUntil {
            message = timedMessage
        } else if audioBlocked && ProcessInfo.processInfo.systemUptime < audioBlockedNoticeUntil {
            message = "no audio: allow \(AppInfo.name) in System Settings › Privacy & Security › Screen & System Audio Recording, then relaunch"
        }
        let help = showHelp ? helpLocked() : nil
        // Kept a moment past their display time so every screen gets to stamp them.
        let now = ProcessInfo.processInfo.systemUptime
        let popups = [songTitle, clockPopup].compactMap { $0 }.filter { now - $0.shownAt < TextPopup.duration + 0.5 }
        return HUDText(message: message, showFPS: showFPS, helpLeft: help?.controls, helpRight: help?.effects, popups: popups)
    }

    func handleKeyDown(_ event: NSEvent) {
        switch event.keyCode {
        case 53: // Escape: cancels an in-progress mode entry if there is one
            // (matching the original's documented "ESC cancels an
            // in-progress command; press it again to exit"), otherwise quits.
            lock.lock()
            let hadPendingEntry = pendingEntry != nil
            pendingEntry = nil
            lock.unlock()
            if !hadPendingEntry {
                NSApp.terminate(nil)
            }
        case let code where Self.digitKeys[code] != nil:
            let digit = Self.digitKeys[code]!
            lock.lock()
            var entry = pendingEntry ?? (.mode, [])
            entry.digits.append(digit)
            if entry.digits.count >= 2, let number = Int(String(entry.digits)) {
                pendingEntry = nil
                completeEntryLocked(entry.kind, number: number)
            } else {
                pendingEntry = entry
            }
            lock.unlock()
        case Self.rateDownKeyCode, Self.rateUpKeyCode:
            lock.lock()
            let mode = _effectState.mode
            if let stars = ratings.adjust(mode: mode, by: event.keyCode == Self.rateUpKeyCode ? 1 : -1) {
                // `SHOW_MODEPREFS_MSG`: " Mode %d: [***] (%d stars) "
                showTimedMessageLocked("mode \(Self.formatMode(mode)): \(ModeNames.name(for: mode))  [\(String(repeating: "*", count: stars))] (\(stars) stars)", seconds: 2)
            }
            lock.unlock()
        case Self.clockKeyCode:
            lock.lock()
            clockEnabled.toggle()
            if clockEnabled {
                showClockLocked()
            } else {
                showTimedMessageLocked("clock off")
            }
            lock.unlock()
        case Self.colorModeKeyCode:
            lock.lock()
            if _effectState.eightBit {
                // The original's T: palette lock. Sound sync was truecolor
                // only, so the 8-bit look just toggles the lock.
                let locking = _effectState.colorMode != .locked
                setColorModeLocked(locking ? .locked : .drift)
                showTimedMessageLocked(locking ? " - palette is LOCKED - " : " - palette is unlocked - ")
            } else {
                setColorModeLocked(_effectState.colorMode.next)
                showTimedMessageLocked("color: \(_effectState.colorMode.label)")
            }
            lock.unlock()
        case Self.eightBitKeyCode:
            lock.lock()
            _effectState.eightBit.toggle()
            showTimedMessageLocked(_effectState.eightBit ? "8-bit look on" : "8-bit look off")
            lock.unlock()
        case Self.newColorKeyCode:
            lock.lock()
            if _effectState.eightBit {
                // The original's P. It did nothing while the palette was
                // locked; here it picks a new palette to stay locked on,
                // like the truecolor lock.
                rollPaletteLocked()
                showTimedMessageLocked(_effectState.colorMode == .locked ? "new palette (locked)" : "new palette")
            } else if _effectState.colorMode == .sound {
                // The time color is only 3% of the mix there.
                showTimedMessageLocked("color follows the sound (c: drift or lock it)", seconds: 2)
            } else {
                jumpColorLocked()
                showTimedMessageLocked(_effectState.colorMode == .locked ? "new color (locked)" : "new color")
            }
            lock.unlock()
        case Self.mouseSteeringKeyCode:
            lock.lock()
            mouseSteers.toggle()
            showTimedMessageLocked(mouseSteers ? "mouse steers the center" : "mouse steering off")
            lock.unlock()
        case Self.songTitleKeyCode:
            lock.lock()
            showSongTitleLocked()
            lock.unlock()
        case Self.variantKeyCode:
            lock.lock()
            rollVariantLocked()
            lock.unlock()
        case Self.loadPresetKeyCode, Self.savePresetKeyCode:
            lock.lock()
            pendingEntry = (event.keyCode == Self.loadPresetKeyCode ? .loadPreset : .savePreset, [])
            lock.unlock()
        case Self.waveformCycleKeyCode:
            lock.lock()
            _effectState.waveformType = (_effectState.waveformType + 1) % 7
            lock.unlock()
        case Self.solarToggleKeyCode:
            lock.lock()
            _effectState.solarEnabled.toggle()
            lock.unlock()
        case Self.shadeToggleKeyCode:
            lock.lock()
            _effectState.shadeEnabled.toggle()
            lock.unlock()
        case Self.chasersToggleKeyCode:
            lock.lock()
            _effectState.chaserCount = _effectState.chaserCount == 0 ? Int.random(in: 1...2) : 0
            lock.unlock()
        case Self.barToggleKeyCode:
            lock.lock()
            _effectState.barEnabled.toggle()
            lock.unlock()
        case Self.dotsToggleKeyCode:
            lock.lock()
            _effectState.dotsEnabled.toggle()
            lock.unlock()
        case Self.nuclideToggleKeyCode:
            lock.lock()
            _effectState.nuclideEnabled.toggle()
            lock.unlock()
        case Self.gridToggleKeyCode:
            lock.lock()
            _effectState.gridEnabled.toggle()
            lock.unlock()
        case Self.fpsToggleKeyCode:
            lock.lock()
            _effectState.frameRateMode = _effectState.frameRateMode.next
            // Like the original's misc toggle notices (e.g. Winamp shuffle).
            showTimedMessageLocked(_effectState.frameRateMode.label)
            lock.unlock()
        case Self.lockToggleKeyCode:
            lock.lock()
            let now = ProcessInfo.processInfo.systemUptime
            if _effectState.locked {
                modeStartTime += now - lockedAt
            } else {
                lockedAt = now
            }
            _effectState.locked.toggle()
            showTimedMessageLocked(_effectState.locked ? "- screen is LOCKED -" : "- screen is unlocked -")
            lock.unlock()
        case let code where Self.helpKeyCodes.contains(code):
            lock.lock()
            showHelp.toggle()
            lock.unlock()
        case Self.fpsDisplayKeyCode:
            lock.lock()
            showFPS.toggle()
            lock.unlock()
        case Self.newModeKeyCode:
            lock.lock()
            switchModeLocked(to: ratings.pickMode())
            showModeConfirmationLocked()
            lock.unlock()
        case Self.waveDownKeyCode, Self.waveUpKeyCode:
            lock.lock()
            let delta = event.keyCode == Self.waveUpKeyCode ? 1 : -1
            _effectState.waveScaleStep = min(10, max(-10, _effectState.waveScaleStep + delta))
            lock.unlock()
        case Self.slideShiftKeyCode:
            lock.lock()
            _effectState.slideShiftEnabled.toggle()
            if !_effectState.slideShiftEnabled { _effectState.slideOffset = .zero }
            lock.unlock()
        case Self.soundToggleKeyCode:
            lock.lock()
            soundOn.toggle()
            let on = soundOn
            if on {
                lastSoundTime = ProcessInfo.processInfo.systemUptime // `frames_since_silence = 0`
            } else {
                _latestAudio = AudioAnalysis()
            }
            lock.unlock()
            onSoundToggled?(on)
        default:
            break
        }
    }

    /// The original's WM_MOUSEMOVE: gXC/gYC follow the cursor, clamped to
    /// ±40/±30 original pixels around the screen center.
    func handleMouseMoved(_ event: NSEvent, in view: NSView) {
        let location = view.convert(event.locationInWindow, from: nil)
        let bounds = view.bounds
        guard bounds.width > 0 else { return }
        let originalPixelsPerPoint = Float(640 / bounds.width)
        // AppKit view coordinates are y-up; the renderer's pixel space is y-down.
        let offset = SIMD2(Float(location.x - bounds.midX), Float(bounds.midY - location.y)) * originalPixelsPerPoint

        lock.lock()
        if mouseSteers {
            _effectState.centerOffset = offset.clamped(lowerBound: SIMD2(-40, -30), upperBound: SIMD2(40, 30))
        }
        lock.unlock()
    }

    func handleMouseDown(_ event: NSEvent) {
        // TODO: original screensaver build ignored mouse movement but not
        // clicks for exit purposes in some versions — decide our own convention
        // here rather than inheriting the ambiguity.
    }

    // MARK: - Mode switching

    /// `frames_til_auto_switch`: 550 frames at the original's 30fps
    /// reference, scaled to real time by its fps (main.cpp:4612-4614).
    private static let autoSwitchSeconds: TimeInterval = 550.0 / 30.0

    /// Called every frame from each screen's draw (repeat calls in a frame
    /// are no-ops). The original prepared the next random map in the
    /// background every frame unless locked (video.h:453-456) and applied
    /// it after ~18s — waiting for a big beat when the music had a strong
    /// one, with the threshold easing until it gave in (main.cpp:5230-5245).
    /// Approximated with the port's beat detector: once ready, switch on the
    /// next beat, at once in silence, or after a second interval regardless.
    func tick() {
        lock.lock(); defer { lock.unlock() }
        if clockEnabled && ProcessInfo.processInfo.systemUptime - lastClockShownAt >= Self.clockInterval {
            showClockLocked()
        }
        guard !_effectState.locked else { return }
        let now = ProcessInfo.processInfo.systemUptime
        let readyTime = modeStartTime + Self.autoSwitchSeconds
        guard now >= readyTime else { return }
        if soundEmptyLocked || lastBeatTime >= readyTime || now >= readyTime + Self.autoSwitchSeconds {
            switchModeLocked(to: ratings.pickMode())
        }
    }

    /// Everything the original does when a new map is applied, for
    /// automatic and manual switches alike (GenerateChunkOfNewMap's init and
    /// apply parts, main.cpp:4353-4380 and 5243-5345): new mode, randomized
    /// motion, random waveform and center, effects re-rolled, lock cleared,
    /// clock restarted.
    private func switchModeLocked(to mode: Int) {
        _effectState.mode = mode
        // Before the effect re-roll: mode 5 reads the outgoing NUCLIDE state.
        _effectState.motion = ModeMotion.random(forMode: mode, nuclideWasOn: _effectState.nuclideEnabled)
        _effectState.waveformType = Self.randomWaveform(forMode: mode)
        _effectState.centerOffset = SIMD2(Float(Int.random(in: -30..<30) - 1), Float(Int.random(in: -15..<15) - 1))
        _effectState.locked = false
        variantNumber = 1
        rollEffectsLocked()
        _effectState.slideShiftEnabled = Int.random(in: 1...100) <= 33 // g_SlideShiftFreq
        if !_effectState.slideShiftEnabled { _effectState.slideOffset = .zero }
        // FX_Random_Palette on every switch, a no-op while locked. Rolled
        // with the 8-bit look off too, so it's ready when turned on.
        if _effectState.colorMode != .locked { rollPaletteLocked() }
        _effectState.modeSwitchCount += 1
        modeStartTime = ProcessInfo.processInfo.systemUptime
    }

    private func rollPaletteLocked() {
        _effectState.palette = .random(silent: soundEmptyLocked)
        _effectState.paletteSerial += 1
    }

    /// `(rand() % 17)/3 + 1` — styles 1-6, 6 slightly rarer — rerolled away
    /// from the combinations the original excluded (main.cpp:4370-4379).
    private static func randomWaveform(forMode mode: Int) -> Int {
        let mode = Modes.original(mode)
        while true {
            let style = Int.random(in: 0..<17) / 3 + 1
            let excluded = (mode == 6 && style == 5)
                || (mode == 12 && (style == 4 || style == 6))
                || (mode == 14 && (style == 3 || style == 4))
                || ([8, 23, 24].contains(mode) && style == 6)
            if !excluded { return style }
        }
    }

    // MARK: - Per-mode effect roll

    /// The original's per-mode `effect_freq` odds (per 1000) and effect-count
    /// limits (main.cpp:4009-4222; CModeInfo defaults min 1, max 2), before
    /// its 32-bit adjustments.
    private struct EffectOdds {
        var chasers, bar, dots, solar, grid, nuclide, shade: Int
        var minEffects = 1
        var maxEffects = 2
    }

    private static func effectOdds(forMode mode: Int) -> EffectOdds {
        switch mode {
        case 1: return EffectOdds(chasers: 220, bar: 150, dots: 10, solar: 680, grid: 4, nuclide: 170, shade: 400)
        case 2: return EffectOdds(chasers: 750, bar: 500, dots: 750, solar: 750, grid: 0, nuclide: 0, shade: 0, maxEffects: 5)
        case 3: return EffectOdds(chasers: 100, bar: 100, dots: 100, solar: 500, grid: 10, nuclide: 0, shade: 300)
        case 4: return EffectOdds(chasers: 500, bar: 100, dots: 100, solar: 100, grid: 30, nuclide: 0, shade: 0)
        case 5: return EffectOdds(chasers: 100, bar: 350, dots: 100, solar: 500, grid: 15, nuclide: 180, shade: 500)
        case 6: return EffectOdds(chasers: 400, bar: 120, dots: 200, solar: 0, grid: 0, nuclide: 0, shade: 0)
        case 7: return EffectOdds(chasers: 50, bar: 200, dots: 0, solar: 300, grid: 0, nuclide: 600, shade: 350)
        case 8: return EffectOdds(chasers: 150, bar: 150, dots: 150, solar: 150, grid: 25, nuclide: 0, shade: 0)
        case 9: return EffectOdds(chasers: 450, bar: 200, dots: 50, solar: 200, grid: 0, nuclide: 100, shade: 200)
        case 10: return EffectOdds(chasers: 150, bar: 20, dots: 80, solar: 0, grid: 0, nuclide: 80, shade: 0, minEffects: 0, maxEffects: 2)
        case 11: return EffectOdds(chasers: 360, bar: 200, dots: 230, solar: 550, grid: 10, nuclide: 330, shade: 150, minEffects: 0, maxEffects: 4)
        case 12: return EffectOdds(chasers: 360, bar: 200, dots: 230, solar: 0, grid: 0, nuclide: 330, shade: 0, minEffects: 0, maxEffects: 2)
        case 13, 14: return EffectOdds(chasers: 500, bar: 0, dots: 100, solar: 0, grid: 30, nuclide: 0, shade: 0)
        case 15: return EffectOdds(chasers: 0, bar: 0, dots: 0, solar: 0, grid: 0, nuclide: 200, shade: 0, minEffects: 0, maxEffects: 1)
        case 16: return EffectOdds(chasers: 500, bar: 100, dots: 100, solar: 100, grid: 30, nuclide: 0, shade: 0)
        default: return EffectOdds(chasers: 150, bar: 150, dots: 150, solar: 150, grid: 12, nuclide: 0, shade: 50, maxEffects: 3)
        }
    }

    /// The original's on-mode-switch effect roll (main.cpp:5320-5345 and
    /// CModeInfo::Clip_Num_Effects, main.cpp:1297): each effect turns on
    /// with its mode's odds (x0.7 while sound plays), then the count is
    /// clipped to the mode's limits — the minimum only enforced in silence.
    /// Overrides manual toggles, as every mode switch did in the original.
    private func rollEffectsLocked() {
        let base = Self.effectOdds(forMode: Modes.original(_effectState.mode))
        // 32-bit adjustments (main.cpp:4226-4235). Index order: CHASERS,
        // BAR, DOTS, SOLAR, GRID, NUCLIDE, SHADE.
        let odds = [
            max(0, min(900, base.chasers - 50)),
            min(900, base.bar + 220),
            min(900, base.dots + 220),
            base.solar,
            min(1000, base.grid + 8),
            min(900, Int(Float(base.nuclide) * 1.3)),
            min(900, base.shade + 150),
        ]
        let hasSound = !soundEmptyLocked
        var on = odds.map { Int.random(in: 0..<1000) < (hasSound ? Int(Float($0) * 0.7) : $0) }
        func count() -> Int { on.filter { $0 }.count }

        if !hasSound {
            var attempts = 0
            while count() < base.minEffects && attempts < 10_000 {
                if let j = on.indices.first(where: { !on[$0] && Int.random(in: 0..<1000) < odds[$0] }) {
                    on[j] = true
                }
                attempts += 1
            }
        }
        while count() > base.maxEffects {
            on[Int.random(in: 0..<on.count)] = false
        }

        _effectState.chaserCount = on[0] ? Int.random(in: 1...2) : 0
        _effectState.barEnabled = on[1] && !on[4] // grid on → heavy bar off (main.cpp:5340)
        _effectState.dotsEnabled = on[2]
        _effectState.solarEnabled = on[3]
        _effectState.gridEnabled = on[4]
        _effectState.nuclideEnabled = on[5]
        _effectState.shadeEnabled = on[6]
    }

    /// Human-readable current state for display in the window title — there's
    /// no on-screen HUD text yet, so this is the only feedback the user gets
    /// while typing a two-digit mode number.
    func titleStatus() -> String {
        lock.lock(); defer { lock.unlock() }
        if let entry = pendingEntryTextLocked() {
            return entry
        }
        let mode = _effectState.mode
        let modeStr = Self.formatMode(mode)
        let s = _effectState
        let effects = [
            (s.solarEnabled, "solar"), (s.shadeEnabled, "shade"),
            (s.chaserCount > 0, "chasers"), (s.barEnabled, "bar"), (s.dotsEnabled, "dots"),
            (s.nuclideEnabled, "nuclide"), (s.gridEnabled, "grid"),
        ].filter(\.0).map(\.1).joined(separator: "+")
        let extras = [
            (s.slideShiftEnabled, "shift"),
            (s.waveScaleStep != 0, "wave gain \(s.waveScaleStep > 0 ? "+" : "")\(s.waveScaleStep)"),
            (!soundOn, "sound off"),
            (s.eightBit, "8-bit"),
            (s.colorMode != .drift, "color \(s.colorMode.label)"),
        ].filter(\.0).map { ", \($0.1)" }.joined()
        return "mode \(modeStr) \(ModeNames.name(for: mode))\(s.locked ? " (locked)" : ""), wave \(WaveformNames.name(for: s.waveformType))\(effects.isEmpty ? "" : ", \(effects)")\(extras), \(s.frameRateMode.label)"
    }
}
