import Foundation

/// Replaces the constellation of global mutable variables main.cpp used for
/// current mode/color/mouse-driven parameters (e.g. g_bSyncColorToSound,
/// shifting). One struct, owned by InputController, read each
/// frame by MetalRenderer.
struct EffectState {
    /// Geiss's original mode numbering (see MetalRenderer's modeParameters) —
    /// all 25 are ported. Default is 5, Geiss's own 5-star flagship
    /// "SUPER-perspective" mode.
    var mode: Int = 5
    /// Bumped on every mode selection (re-selecting the same mode counts,
    /// as in the original), so the renderer can run its on-switch effects.
    var modeSwitchCount: Int = 0
    /// This visit's randomized motion parameters (see ModeMotion).
    var motion = ModeMotion()
    /// Geiss's original waveform numbering (1-6; 0 = off), cycled with 'W'.
    /// See MetalRenderer's wave-stamp pass for what each style draws.
    var waveformType: Int = 1
    /// 'C' — see ColorMode. Survives mode switches.
    var colorMode: ColorMode = .drift
    /// The color clock, the original's `intfram`: frames at 30fps. Kept by
    /// InputController (frozen while the color is locked, jumped by 'P').
    var colorTime: Float = 0
    /// 'B' — the 8-bit look (see EightBitPalette). While on, the color lock
    /// is the original's palette lock and 'P' its new-palette key.
    var eightBit: Bool = false
    /// The current 8-bit palette, re-rolled on every mode switch unless the
    /// color is locked; `paletteSerial` bumps with each new one so the
    /// renderer knows to crossfade.
    var palette = EightBitPalette()
    var paletteSerial: Int = 0
    /// Overlay effects — independent of the plasma mode entirely, see
    /// ORIGINAL_FEATURE_REFERENCE.md §4 and OverlayEffects.swift. The
    /// original's keys: 'Y' SOLAR, 'E' SHADE, 'Q' CHASERS, 'U' BAR, 'D'
    /// DOTS, 'A' NUCLIDE, 'G' GRID.
    var solarEnabled: Bool = true
    var shadeEnabled: Bool = true
    /// 0 = off; 1 or 2 chasers (`effect[CHASERS] = 1 + rand()%2`).
    var chaserCount: Int = 0
    var barEnabled: Bool = false
    var dotsEnabled: Bool = false
    /// Only visible while the sound is empty, as in the original.
    var nuclideEnabled: Bool = false
    var gridEnabled: Bool = false
    /// Cycled with 'S'. See MetalRenderer's per-frame clock comment.
    /// Default 60fps smooth (the user's choice): classic speed, smoother.
    var frameRateMode: FrameRateMode = .smooth60
    /// gXC/gYC — the zoom/rotation center, as an offset from screen center in
    /// original (640-wide) pixels, y down. Randomized on each mode switch
    /// (`new_gXC = FXW/2-1 + rand()%60-30`, main.cpp:4360) and set by mouse
    /// movement, clamped to ±40/±30 (main.cpp:6726-6736).
    var centerOffset: SIMD2<Float> = .zero
    /// 'L' — stops automatic mode switching until unlocked or the next
    /// manual mode switch (the original clears it on every switch).
    var locked: Bool = false
    /// 'J'/'K' — wave height in the original's `volpos` steps, -10...10,
    /// each ×1.25 (main.cpp:7444-7460). Survives mode switches.
    var waveScaleStep: Int = 0
    /// 'I' / `g_bSlideShift` — on beats, the whole image starts drifting by
    /// a small constant offset (original pixels per frame) until the next
    /// beat; rolled on for 33% of mode switches (main.cpp:5321, 8825-8850).
    var slideShiftEnabled: Bool = false
    var slideOffset: SIMD2<Float> = .zero
}

enum FrameRateMode: CaseIterable {
    /// Matches the original's per-frame motion speed on its era's hardware.
    case classic30
    /// Every per-frame step unscaled at 60fps: zoom, rotation, fade and
    /// particles all run twice as fast. Not the original's behavior — it
    /// scaled its zoom/rotation by 30/fps (main.cpp:4636-4637) — but kept
    /// as an option.
    case fast60
    /// 60fps at classic speed — every per-frame step scaled by half. The
    /// closest to the original at 60fps, which compensated its motion
    /// (though not its fade or particle counts).
    case smooth60

    var fps: Int { self == .classic30 ? 30 : 60 }

    /// Multiplier on every per-frame step, so smooth60 moves at classic30's
    /// real-time speed.
    var stepScale: Float { self == .smooth60 ? 0.5 : 1 }

    var label: String {
        switch self {
        case .classic30: return "30fps"
        case .fast60: return "60fps fast"
        case .smooth60: return "60fps smooth"
        }
    }

    var next: FrameRateMode {
        let all = Self.allCases
        return all[(all.firstIndex(of: self)! + 1) % all.count]
    }
}
