import Foundation

/// 'C' — where the scene color comes from. The original had the first two
/// (the setup dialog's "sync color to sound", `g_bSyncColorToSound`, off by
/// default); `locked` is a port addition at the user's request.
enum ColorMode: CaseIterable {
    /// The original's default: an endlessly drifting hue (main.cpp:8955-9016).
    case drift
    /// The original's "sync color to sound" (main.cpp:8907-8954): bass reds,
    /// mids greens, treble blues.
    case sound
    /// The drift frozen on its current color; 'P' picks another.
    case locked

    var label: String {
        switch self {
        case .drift: return "drift"
        case .sound: return "sync to sound"
        case .locked: return "locked"
        }
    }

    var next: ColorMode {
        let all = Self.allCases
        return all[(all.firstIndex(of: self)! + 1) % all.count]
    }
}

/// The original's waveform/effect color (main.cpp:8901-9016). `base` stands
/// in for its 0-255 brightness; the port passes its 0-1 loudness, and the
/// renderer clamps the result.
enum SceneColor {
    /// Stand-in for the original's `gF[0...5]` — 6 per-run-random frequencies
    /// (`main.cpp:3978`: `gF[z] = (rand()%1000)*0.001*0.01 + 0.02`, i.e.
    /// ~0.02-0.03 rad/frame) driving each color channel's independent
    /// sin/cos pair. Fixed representative values, same approach as every
    /// other mode's "random" constants throughout this port.
    static let frequencies: [Float] = [0.021, 0.027, 0.024, 0.029, 0.022, 0.026]

    /// The time-based color: each channel an independent sin/cos product
    /// with a slowly wandering phase `f`. `t` is the original's `intfram`
    /// (frames at 30fps). The default mode uses c1/c2 = 0.55/0.50 (v4.26+);
    /// sound sync mixes in 3% of the older 0.3/0.2 version.
    static func time(t: Float, base: Float, c1: Float = 0.55, c2: Float = 0.50) -> SIMD3<Float> {
        let f = 7 * sin(t * 0.006 + 59) + 5 * cos(t * 0.0077 + 17)
        let g = frequencies
        return base * 1.07 * SIMD3(
            (1 + c1 * sin(t * g[0] + 10 - f)) * (1 + c2 * cos(t * g[1] + 37 + f)),
            (1 + c1 * sin(t * g[2] + 32 + f)) * (1 + c2 * cos(t * g[3] + 16 - f)),
            (1 + c1 * sin(t * g[4] + 87 - f)) * (1 + c2 * cos(t * g[5] + 25 + f))
        )
    }

    /// "Sync color to sound": the smoothed band powers summed into red
    /// (lowest 31%), green (30-59%) and blue (56-100%) — the ranges overlap
    /// by a band, as in the original — weighted, normalized to length
    /// `base`, and mixed 97/3 with the old time color.
    static func sound(bands: [Float], t: Float, base: Float) -> SIMD3<Float> {
        let n = Float(bands.count)
        func sum(_ from: Float, _ to: Float) -> Float {
            // The original's loops: int a from Int(from*N) while a < to*N.
            var total: Float = 0
            var a = Int(from * n)
            while Float(a) < to * n {
                total += bands[a]
                a += 1
            }
            return total
        }
        var c = SIMD3(sum(0, 0.31) * 0.93, sum(0.30, 0.59) * 1.18, sum(0.56, 1) * 2.40)
        c.x -= c.z * 0.4
        let length = (c * c).sum().squareRoot()
        // Silence: nothing to normalize; the original divided by zero here.
        let frequencyColor = length > 0 ? c * (base / length) : SIMD3(repeating: 0)
        return (frequencyColor * 0.97 + time(t: t, base: base, c1: 0.3, c2: 0.2) * 0.03) * 1.35
    }
}

/// The original's `g_power_smoothed` (main.cpp:8273-8289): FOURIER_DETAIL
/// (24) log-spaced bands from 20Hz up (20·2^(n·10/24) Hz, band 0 unused),
/// each a single DFT bin over the latest 256 samples at 44.1kHz — short
/// and unwindowed, so the low bands overlap heavily, which the color
/// weights were tuned around. Here the window keeps the same duration at
/// the capture's sample rate. Smoothed 0.94/0.06 per original frame.
struct SoundBands {
    static let count = 24
    private(set) var smoothed = [Float](repeating: 0, count: SoundBands.count)

    /// `step` is the renderer's per-frame step (0.5 at 60fps smooth), so the
    /// smoothing runs at the original's per-30fps-frame rate.
    mutating func update(waveform: [Float], sampleRate: Float, step: Float) {
        let length = min(waveform.count, Int((256 * sampleRate / 44100).rounded()))
        guard length > 0 else { return }
        let samples = waveform.suffix(length)
        let keep = pow(0.94, step)
        for band in 1..<Self.count {
            let hz = 20 * pow(2, Float(band) / Float(Self.count) * 10)
            let w = 2 * Float.pi * hz / sampleRate
            var re: Float = 0, im: Float = 0
            for (i, sample) in samples.enumerated() {
                re += sample * cos(w * Float(i))
                im += sample * sin(w * Float(i))
            }
            let power = (re * re + im * im).squareRoot()
            smoothed[band] = smoothed[band] * keep + power * (1 - keep)
        }
    }
}
