import Foundation

/// The mode range. 1-25 are the original's; 26 is the port's own —
/// "smooth vortex", mode 6 with the half-strength pull and longer trails
/// the user tuned before mode 6 was restored to the original's force.
enum Modes {
    static let count = 26
    static let all = 1...count

    /// The original mode a port-added mode is built on, for the per-mode
    /// tables (effect odds, waveform exclusions, motion ranges).
    static func original(_ mode: Int) -> Int {
        mode == 26 ? 6 : mode
    }
}

/// The motion parameters the original re-randomizes every time a mode is
/// entered (GenerateChunkOfNewMap's init part, main.cpp:4353-4574), so no
/// two visits to a mode look quite the same. Rolled once per switch by
/// InputController so every screen shares the same values; read by the
/// renderer each frame.
struct ModeMotion: Codable {
    /// Rotation per frame, radians (after the original's random sign flip
    /// and `*0.6`).
    var turn1: Float = 0
    /// Per-mode shader parameters — meaning varies by mode, see
    /// Shaders.metal's scale_for_mode / mode11_source.
    var f1: Float = 0
    var f2: Float = 0
    var f3: Float = 0
    /// The original's `new_damping`: map damping is disabled
    /// (`suggested_damping = 1.0f`, main.cpp:8308), then halved for the
    /// modes flagged in `mode_motion_dampened` (main.cpp:1223, 4368).
    var damping: Float = 1
    /// Mode 6's point sources, positions as fractions of the screen.
    var vortexPoints: [VortexSpec] = []

    struct VortexSpec: Codable {
        var position: SIMD2<Float>
        var direction: SIMD2<Float>
        var type: Int32
    }

    /// `(rand()%1000)*0.001`
    private static func u() -> Float { Float(Int.random(in: 0..<1000)) * 0.001 }

    private static let dampenedModes: Set<Int> = [1, 2, 4, 5, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16]

    /// - Parameter nuclideWasOn: mode 5's zoom curve depends on whether
    ///   NUCLIDE was on while its map generated — i.e. the *previous* mode's
    ///   roll, since effects are re-rolled when the map is applied.
    static func random(forMode mode: Int, nuclideWasOn: Bool) -> ModeMotion {
        var m = ModeMotion()
        var turn1: Float = 0
        var turn2: Float = 0
        var scale1: Float = 1
        var scale2: Float = 1

        switch Modes.original(mode) {
        case 1:
            scale1 = 0.985 - 0.12 * pow(u(), 2)
            turn1 = 0.01 + 0.01 * u()
            if scale1 > 0.97 && Int.random(in: 0..<3) == 1 { turn1 *= -1 }
            m.f1 = scale1
        case 2:
            m.f1 = 1.00 + 0.02 * u()
            turn1 = 0.02 + 0.07 * u()
        case 3:
            turn1 = 0.01 + 0.015 * u()
        case 5:
            turn1 = 0.01 + 0.03 * u()
            m.f1 = 0.05 + 0.05 * u() + 0.07 * u()
            m.f2 = 0.99 - 0.01 * u() - 0.02 * u()
            // Linear instead of sqrt falloff when NUCLIDE was on (main.cpp:4713-4716).
            m.f3 = nuclideWasOn ? 1 : 0
        case 6:
            m.vortexPoints = (0..<5).map { _ in
                let angle = Float(Int.random(in: 0..<628)) * 0.01
                let strength = 1 + Float(Int.random(in: 0..<80)) * 0.01
                return VortexSpec(position: SIMD2(u(), u()),
                                  direction: SIMD2(cos(angle), sin(angle)) * strength,
                                  type: Int32.random(in: 0..<3))
            }
            // Vortex gain: the original's full force for mode 6; half for
            // the port's mode 26 (see vortex_source in Shaders.metal).
            m.f1 = mode == 26 ? 0.5 : 1
        case 7:
            turn1 = 0.01 + 0.01 * u()
            m.f1 = 0.92 + 0.01 * u()
            m.f2 = 0.0006 + 0.0005 * u()
        case 8:
            turn1 = 0.05 * u()
            m.f1 = 8 * pow(u(), 4) + 1.5
        case 9:
            turn1 = 0.01 + 0.03 * u()
            // The init-time scale1 survives as scale2, the constant zoom on
            // the checkerboard's other half (rotation_dither[9]); the shader
            // applies protective_factor to it.
            m.f3 = 0.8 + 0.25 * u()
            m.f1 = 0.98 + 0.01 * u()
            m.f2 = 0.0009 + 0.0012 * u()
        case 11:
            scale1 = 1.008 + 0.008 * u()
            scale2 = scale1
            turn1 = 0.12 + 0.06 * u()
            turn2 = turn1
            turn1 *= -0.6
            turn2 *= 0.1
            scale1 *= 0.99
            scale2 *= 1.01
        case 13:
            turn1 = 0.007 + 0.02 * u()
            m.f1 = 0.92 + 0.16 * u()
        case 15:
            turn1 = 0.04 * u() + 0.045 * u()
            m.f1 = Float(Int.random(in: 2...6)) // petals
            m.f2 = 0.92 + 0.06 * u()
            m.f3 = 0.05 + 0.05 * u()
        case 10, 12:
            break // custom motion vectors, no rotation
        default: // 4, 14, 16, 17+
            turn1 = 0.007 + 0.02 * u()
        }

        if Bool.random() {
            turn1 *= -1
            turn2 *= -1
        }
        turn1 *= 0.6
        turn2 *= 0.6

        if mode == 11 {
            m.f1 = scale1
            m.f2 = scale2
            m.f3 = turn2
        }
        // Mode 24 overrides its spin in the per-pixel loop: a fixed 0.05,
        // no sign flip or `*0.6` (main.cpp:4866).
        m.turn1 = mode == 24 ? 0.05 : turn1
        m.damping = dampenedModes.contains(Modes.original(mode)) ? 0.5 : 1
        return m
    }
}
