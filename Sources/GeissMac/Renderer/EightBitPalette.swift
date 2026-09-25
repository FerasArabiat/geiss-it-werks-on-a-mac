import Foundation

/// 'B' — the 8-bit look: the original's 256-color display mode, where the
/// buffer held one brightness per pixel and a palette turned it into color
/// (video.h FX_Random_Palette / CrankPal). A new random palette on every mode
/// switch unless locked, crossfaded in over 9 frames (PutPalette).
///
/// This struct is the palette's recipe, as the original kept it in
/// `old_palette` for presets; `table()` builds the 256 colors.
struct EightBitPalette: Codable, Equatable {
    /// 0-3: one of the four fixed palettes "from original FX"; nil: three
    /// random curves.
    var monotone: Int?
    /// CrankPal curve ids (1-7) for red, blue and green, in that order —
    /// the original's c1, c2, c3 (c2 fed `peBlue`).
    var curves: [Int] = [1, 2, 3]
    /// `[lo, hi]`: entries strictly between them are doubled — the
    /// "coarse" banding.
    var band: [Int]?
    /// Rolled during silence: 30% brighter (`if (SoundEmpty) gamma_factor
    /// += 0.3`; the gamma slider itself defaulted to 0).
    var silenceBoost = false

    /// FX_Random_Palette's roll with the setup dialog's defaults
    /// (`coarse_pal_freq` = `solar_pal_freq` = 1).
    static func random(silent: Bool) -> EightBitPalette {
        var palette = EightBitPalette(silenceBoost: silent)
        if Int.random(in: 0..<10) < 1 {
            palette.band = [7 + Int.random(in: 0..<6), 17 + Int.random(in: 0..<6)]
        }
        if Int.random(in: 0..<6) == 0 {
            palette.monotone = Int.random(in: 0..<4)
            return palette
        }
        repeat {
            // Curve 7 (the wavy "solar" one) only in a fifth of palettes.
            let highest = Int.random(in: 0..<5) < 1 ? 7 : 6
            palette.curves = (0..<3).map { _ in Int.random(in: 1...highest) }
        } while palette.curves.filter { $0 == 6 }.count > 1 // "disallow really dark palettes"
        return palette
    }

    /// The 256 colors, RGBA. Values truncate to bytes, as they did into the
    /// original's PALETTEENTRY.
    func table() -> [SIMD4<UInt8>] {
        func byte(_ value: Float) -> UInt8 { UInt8(max(0, min(255, value))) }

        if let monotone {
            // REMAP / REMAP2 / REMAP3 for entries 0-127, then flat.
            let square = { (a: Float) in a * a / 64 }
            let double = { (a: Float) in a * 2 }
            let root = { (a: Float) in a.squareRoot() * 22.6 }
            let (red, blue, green): ((Float) -> Float, (Float) -> Float, (Float) -> Float) = switch monotone {
            case 0: (square, double, root)
            case 1: (square, root, double)
            case 2: (root, double, square)
            default: (double, square, root)
            }
            return (0..<256).map { n in
                let a = Float(min(n, 127))
                return SIMD4(byte(red(a)), byte(green(a)), byte(blue(a)), 255)
            }
        }

        let gammaFactor: Float = silenceBoost ? 1.3 : 1
        return (0..<256).map { n in
            var c = SIMD3(Self.crank(curves[0], n), Self.crank(curves[1], n), Self.crank(curves[2], n)) * gammaFactor
            if let band, n > band[0] && n < band[1] { c *= 2 }
            // c is (red, blue, green).
            return SIMD4(byte(c.x), byte(c.z), byte(c.y), 255)
        }
    }

    /// The original's `CrankPal` (video.h:1598): entry `z` of curve `id`.
    private static func crank(_ id: Int, _ z: Int) -> Float {
        let x = Float(z)
        switch id {
        case 1: return x.squareRoot() * 22.6
        case 2: return x * 2
        case 3: return x * x / 64
        case 4: return 255 * sin(x / 256 * 0.5 * .pi)
        case 5: return x * 3.5
        case 6: return pow(1.5, x / 20) - 1 // "this is really dark!"
        case 7: return x * 1.5 + 128 * 0.25 + 128 * 0.25 * sin(x * 0.3)
        default: return 255
        }
    }
}
