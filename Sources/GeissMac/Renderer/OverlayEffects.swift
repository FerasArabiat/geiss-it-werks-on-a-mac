import simd

/// One point sprite in the overlay pass. Layout-coupled to particle_vertex
/// (position.xy, size, shape) — see MetalRenderer's upload loop.
struct Sprite {
    enum Shape: Float {
        case glow = 0    // flat-topped soft disc — SOLAR/SHADE
        case cone = 1    // linear falloff — NUCLIDE's `(r - dist)*25`
        case square = 2  // hard square — the original's single-pixel stamps
    }
    var position: SIMD2<Float>
    var size: Float
    var color: SIMD4<Float>
    var shape: Shape
}

/// How a batch combines with the feedback texture, matching each effect's
/// pixel math in the original.
enum SpriteBlend {
    case add      // `VS1 += v`
    case screen   // `VS1 = 255 - (255 - VS1)*k` (CHASERS)
    case replace  // `VS1 = v` (DOTS)
    case max      // `if (VS1 < v) VS1 = v` (GRID)
}

struct SpriteBatch {
    var blend: SpriteBlend
    var sprites: [Sprite]
}

/// Per-frame inputs shared by every effect.
struct OverlayFrame {
    var centerPx: SIMD2<Float>        // gXC/gYC
    var resolution: SIMD2<Float>
    var nativePixelScale: Float       // physical px per original (640-wide) px
    var step: Float                   // FrameRateMode.stepScale
    var originalFps: Float            // the fps the original's formulas should see
    var intframe: Float
    var floatframe: Float
    var sceneColor: SIMD4<Float>
    var mode: Int
    var enteredMode: Bool
    var soundEmpty: Bool
}

/// The original's overlay effects (Effects.h, dispatched main.cpp:5489-5538),
/// independent of the plasma mode. Every position/size constant below is in
/// original (640-wide) pixels, scaled by `nativePixelScale`.
final class OverlayEffects {
    /// `chaser_offset = rand() % 40000` at startup (main.cpp:3879) — a
    /// per-run phase for CHASERS, BAR, and NUCLIDE's color.
    private let chaserOffset = Float(Int.random(in: 0..<40000))
    /// The original's `gF[0...5]` (shared with the wave color oscillator).
    private let gF: [Float]

    private var dotTrail: [(position: SIMD2<Float>, color: SIMD4<Float>)] = []
    private var dotAccumulator: Float = 0
    /// `grid_dir`, re-randomized on each mode switch (main.cpp:5345).
    private var gridDirection: Float = 1

    init(colorFrequencies: [Float]) {
        gF = colorFrequencies
    }

    /// Draw order matches the original's.
    func batches(for frame: OverlayFrame, state: EffectState) -> [SpriteBatch] {
        if frame.enteredMode {
            gridDirection = Bool.random() ? 1 : -1
        }
        var result: [SpriteBatch] = []
        func append(_ blend: SpriteBlend, _ sprites: [Sprite]) {
            if !sprites.isEmpty { result.append(SpriteBatch(blend: blend, sprites: sprites)) }
        }
        if state.shadeEnabled { append(.add, shade(frame)) }
        if state.chaserCount > 0 { append(.screen, chasers(frame, count: state.chaserCount)) }
        if state.barEnabled { append(.add, bar(frame)) }
        if state.dotsEnabled { append(.replace, dots(frame)) }
        if state.nuclideEnabled { append(.add, nuclide(frame)) }
        if state.gridEnabled { append(.max, grid(frame)) }
        append(.add, solar(frame, enabled: state.solarEnabled))
        return result
    }

    /// Per-frame counts scale by `step` with random rounding, so smooth60
    /// drops the same number per second as classic30, and classic/fast get
    /// exactly the original's count.
    private func perFrame(_ count: Int, _ step: Float) -> Int {
        Int(Float(count) * step + Float.random(in: 0..<1))
    }

    /// `time_scale = 30/fps_at_last_mode_switch` — CHASERS and DOTS
    /// normalize their clocks to 30fps.
    private func timeScale(_ frame: OverlayFrame) -> Float {
        frame.originalFps >= 10 && frame.originalFps < 120 ? 30 / frame.originalFps : 1
    }

    private func place(_ offset: SIMD2<Float>, _ frame: OverlayFrame) -> SIMD2<Float> {
        frame.centerPx + offset * frame.nativePixelScale
    }

    // MARK: - SHADE

    /// Fixed picks from inside the original's startup random ranges
    /// (main.cpp:3963-3976): orbit freqs `micro_f1..4` 0.10-0.15, color
    /// freq `micro_c1` 0.08-0.17, radii `micro_rad` 2.0-4.8 original px.
    /// One blob: normal operation sets `effect[SHADE] = 1` (main.cpp:5328).
    private let shadeOrbitFreq = SIMD4<Float>(0.112, 0.137, 0.124, 0.146)
    private let shadePulseFreq: Float = 0.11
    private let shadeRadii = SIMD4<Float>(3.1, 2.6, 4.2, 3.7)

    /// `ShadeBobs` (Effects.h:191) — a small glow wobbling quickly around
    /// gXC/gYC (within ~10 original px), which the zoom carries outward into
    /// trails. Each frame drops 4 "+" stamps along a short random walk.
    ///
    /// Color deviates from the source on purpose: the original's per-channel
    /// on/off strobe produced visibly independent hues (confirmed by
    /// pixel-sampling a screenshot after the user flagged "cycles rgb"), so
    /// it shares `sceneColor` with the waveform, varying only brightness.
    private func shade(_ frame: OverlayFrame) -> [Sprite] {
        let t = frame.floatframe
        var a = shadeRadii.x * cos(t * shadeOrbitFreq.x) + shadeRadii.z * cos(t * shadeOrbitFreq.y)
        var b = shadeRadii.y * cos(t * shadeOrbitFreq.z) + shadeRadii.w * cos(t * shadeOrbitFreq.w)
        // 0.25 per stamp because 4 overlapping stamps carry what one sprite used to.
        let pulse = 0.6 + 0.4 * sin(t * shadePulseFreq)
        let color = frame.sceneColor * (pulse * 0.25)
        // The "+" stamp (center +5, 4 neighbors +3, Effects.h:227-231) —
        // 2.6 original px across with the glow falloff matches its light.
        let size = max(2, 2.6 * frame.nativePixelScale)

        return (0..<perFrame(4, frame.step)).map { _ in
            a += Float(Int.random(in: -2...2))
            b += Float(Int.random(in: -2...2))
            return Sprite(position: place(SIMD2(a, b), frame), size: size, color: color, shape: .glow)
        }
    }

    // MARK: - CHASERS

    /// `Two_Chasers` (Effects.h:604) — 1 or 2 points racing along
    /// Lissajous paths around gXC/gYC, each frame tracing a 20-point
    /// segment that pushes pixels toward white (`255-(255-v)*0.6`, i.e.
    /// screen blend with 0.4).
    private func chasers(_ frame: OverlayFrame, count chaserCount: Int) -> [Sprite] {
        let scale = timeScale(frame)
        var t = (frame.floatframe + chaserOffset) * scale
        let color = SIMD4<Float>(0.4, 0.4, 0.4, 1)
        let size = frame.nativePixelScale
        var sprites: [Sprite] = []
        for _ in 0..<perFrame(20, frame.step) {
            t += 0.08 * scale
            for pass in 0..<min(chaserCount, 2) {
                let offset: SIMD2<Float> = pass == 0
                    ? SIMD2(74 * cos(t * 0.1102 + 10) + 65 * cos(t * 0.1312 + 20),
                            54 * cos(t * 0.1204 + 40) + 55 * cos(t * 0.1715 + 30))
                    : SIMD2(64 * cos(t * 0.1213 + 33) + 55 * cos(t * 0.1408 + 15),
                            52 * cos(t * 0.1304 + 12) + 51 * cos(t * 0.1103 + 21))
                sprites.append(Sprite(position: place(offset, frame), size: size, color: color, shape: .square))
            }
        }
        return sprites
    }

    // MARK: - BAR

    /// `Solid_Line` (Effects.h:551) drawn 3 times (main.cpp:5491-5514) — a
    /// short line between two slow Lissajous points near gXC/gYC, +16 per
    /// pixel per frame, once per color channel at phase-shifted positions
    /// (`chromatic_dispersion = 4`) so the channels separate into fringes.
    private func bar(_ frame: OverlayFrame) -> [Sprite] {
        let ff = frame.floatframe
        let base = ff + chaserOffset * 0.6
        let dispersion: Float = 4
        let intensity = 16 / 255 * frame.step
        // VS1 is BGRA: the unshifted line lands in blue, +1 byte green, +2 red.
        let lines: [(phase: Float, color: SIMD4<Float>)] = [
            (base, SIMD4(0, 0, intensity, 1)),
            (base + 3.5 * dispersion * (sin(ff * 0.03 + 1) + cos(ff * 0.04 + 3)), SIMD4(0, intensity, 0, 1)),
            (base - 3.5 * dispersion * (cos(ff * 0.05 + 2) + sin(ff * 0.06 + 4)), SIMD4(intensity, 0, 0, 1)),
        ]
        let size = frame.nativePixelScale
        var sprites: [Sprite] = []
        for line in lines {
            let f = line.phase * 0.55 / (0.08 * 20)
            let p1 = SIMD2<Float>(16 * cos(f * 0.1102 + 10) + 15 * cos(f * 0.1312 + 20),
                                  15 * cos(f * 0.1204 + 40) + 10 * cos(f * 0.1715 + 30))
            let p2 = SIMD2<Float>(14 * cos(f * 0.1213 + 33) + 13 * cos(f * 0.1408 + 15),
                                  13 * cos(f * 0.1304 + 12) + 11 * cos(f * 0.1103 + 21))
            for k in 0..<50 {
                let u = Float(k) / 50
                sprites.append(Sprite(position: place(p1 * u + p2 * (1 - u), frame), size: size, color: line.color, shape: .square))
            }
        }
        return sprites
    }

    // MARK: - DOTS

    /// `One_Dotty_Chaser` (Effects.h:784) — a slow Lissajous point leaving a
    /// 20-dot trail; each dot keeps the color it was born with, is
    /// overwritten into the buffer every frame, and drifts right 1 original
    /// pixel per frame.
    private func dots(_ frame: OverlayFrame) -> [Sprite] {
        let t = frame.floatframe * timeScale(frame)
        dotAccumulator += frame.step
        while dotAccumulator >= 1 {
            dotAccumulator -= 1
            let offset = SIMD2<Float>(64 * cos(t * 0.0613 + 33) + 55 * cos(t * 0.0708 + 15),
                                      52 * cos(t * 0.0704 + 12) + 51 * cos(t * 0.0503 + 21))
            // chaser_r/g/b land in VS1's B/G/R bytes respectively.
            let color = SIMD4<Float>(127 + 126 * sin(t * 0.0513 + 27),
                                     127 + 126 * sin(t * 0.0713 + 30),
                                     127 + 126 * sin(t * 0.0613 + 33),
                                     255) / 255
            dotTrail.append((place(offset, frame), color))
            if dotTrail.count > 20 { dotTrail.removeFirst() }
        }
        // 2x2 "FAT" pixels at the original's >=880px-wide resolutions,
        // single pixels below — about 1.25 original px either way.
        let size = 1.25 * frame.nativePixelScale
        let sprites = dotTrail.map { Sprite(position: $0.position, size: size, color: $0.color, shape: .square) }
        let drift = SIMD2<Float>(frame.nativePixelScale * frame.step, 0)
        for i in dotTrail.indices { dotTrail[i].position += drift }
        return sprites
    }

    // MARK: - NUCLIDE

    /// `Nuclide` (Effects.h:669) — only while the sound is empty: now and
    /// then (1 in 12 frames) a ring of 3-7 glowing "atoms" flashes around
    /// gXC/gYC, each a cone of brightness `(r - dist)*25`, tinted by its own
    /// slow color oscillator.
    private func nuclide(_ frame: OverlayFrame) -> [Sprite] {
        guard frame.soundEmpty, Float.random(in: 0..<1) < frame.step / 12 else { return [] }
        let nodes = 3 + Int.random(in: 0..<5)
        let phase = Float(Int.random(in: 0..<1000))
        let r = Float(3 + Int.random(in: 0..<8))
        let ringRadius = Float(34 + Int.random(in: 0..<8))

        let i = frame.intframe + chaserOffset
        let f = 7 * sin(i * 0.007 + 29) + 5 * cos(i * 0.0057 + 27)
        let cr = 0.5 + 0.25 * sin(i * gF[0] + 20 - f) + 0.25 * cos(i * gF[3] + 17 + f)
        let cg = 0.5 + 0.25 * sin(i * gF[1] + 42 + f) + 0.25 * cos(i * gF[4] + 26 - f)
        let cb = 0.5 + 0.25 * sin(i * gF[2] + 57 - f) + 0.25 * cos(i * gF[5] + 35 + f)
        // cr/cg/cb scale VS1's B/G/R bytes respectively; peak is r*25 at the center.
        let color = SIMD4<Float>(cb, cg, cr, 1) * (r * 25 / 255)

        return (0..<nodes).map { n in
            let angle = Float(n) / Float(nodes) * 6.28 + phase
            let offset = SIMD2(cos(angle), sin(angle)) * ringRadius
            return Sprite(position: place(offset, frame), size: 2 * r * frame.nativePixelScale, color: color, shape: .cone)
        }
    }

    // MARK: - GRID

    /// `Grid` (Effects.h:947) — a lattice of single pixels every FXW/30,
    /// scrolling sideways 1 pixel per frame, all at one pulsing gray level.
    /// Screen-anchored, not centered on gXC/gYC.
    private func grid(_ frame: OverlayFrame) -> [Sprite] {
        let spacing: Float = 21 // Int(640/30)
        let clock = frame.intframe * 30 / frame.originalFps
        let level = max(0, 65 + 45 * sin(clock * 0.06033) + 35 * cos(clock * 0.04710 + 1) + 25 * cos(clock * 0.00523 - 1)) / 255
        let color = SIMD4<Float>(level, level, level, 1)
        let shift = frame.intframe.truncatingRemainder(dividingBy: spacing) * -gridDirection
        let nativeHeight = frame.resolution.y / frame.nativePixelScale
        let size = frame.nativePixelScale

        var sprites: [Sprite] = []
        var y: Float = 0
        while y < nativeHeight {
            var x: Float = 0
            while x < 639 {
                sprites.append(Sprite(position: SIMD2(x + shift, y) * frame.nativePixelScale, size: size, color: color, shape: .square))
                x += spacing
            }
            y += spacing
        }
        return sprites
    }

    // MARK: - SOLAR

    /// The original's per-mode `modeInfo[z].solar_max` (32-bit values,
    /// main.cpp:4009-4223) — SOLAR's density. Mode 15 has no entry there
    /// and uses CModeInfo's default of 60; modes 17+ share 600.
    private func solarMax(forMode mode: Int) -> Float {
        switch Modes.original(mode) {
        case 1: return 800
        case 2: return 35
        case 4, 13, 14, 16: return 34
        case 7: return 65
        case 9: return 50
        case 10: return 0
        case 11: return 750
        case 12: return 500
        case 17...: return 600
        default: return 60
        }
    }

    /// `Drop_Solar_Particles` (Effects.h:439) — sparks scattered in a disc
    /// of 35 original px around gXC/gYC, brightest near the center.
    ///
    /// Color deviates from the source on purpose: the original picks 3
    /// independent random bytes per particle, which read as "cycling the RGB
    /// spectrum"; the user remembered SOLAR matching the waveform color, so
    /// particles share `sceneColor`, varying only brightness.
    ///
    /// Also mode 1's "initial sun": half the time, entering mode 1 drops a
    /// one-off burst of 500 — even with SOLAR off (main.cpp:5342-5343).
    private func solar(_ frame: OverlayFrame, enabled: Bool) -> [Sprite] {
        var count = 0
        if enabled {
            let solarMax = solarMax(forMode: frame.mode)
            let t = frame.intframe
            let fx = 3 + solarMax * 1.6 + solarMax * 0.43 * sin(t * 0.05) + solarMax * 0.43 * sin(t * 0.038 + 1)
            count = perFrame(max(0, Int(fx * 0.05)), frame.step)
        }
        if frame.enteredMode && frame.mode == 1 && Bool.random() {
            count += 500
        }
        // 3.5 original px across with the glow falloff carries about the
        // same light as the original's 3x3 stamp (Effects.h:496-509).
        let size = max(2, 3.5 * frame.nativePixelScale)
        let hue = SIMD4(frame.sceneColor.x, frame.sceneColor.y, frame.sceneColor.z, 1)

        return (0..<count).map { _ in
            var x: Float = 0, y: Float = 0, dist: Float = 100
            var attempts = 0
            while dist >= 35 && attempts < 50 {
                y = Float.random(in: -36...36)
                x = Float.random(in: -48...48)
                dist = sqrt(x * x + y * y)
                attempts += 1
            }
            let brightness = Float.random(in: 0.5...1.0) * max(0, (35 - dist) / 35)
            return Sprite(position: place(SIMD2(x, y), frame), size: size, color: hue * brightness, shape: .glow)
        }
    }
}
