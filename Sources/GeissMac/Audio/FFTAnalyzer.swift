import Accelerate

/// Result of one FFT pass — the modern equivalent of what SOUND.CPP's GetWaveData()
/// produced for the original's spectrum-driven wave coloring and beat detection.
struct FFTResult {
    var spectrum: [Float] = []
    var bass: Float = 0
    var treble: Float = 0
}

/// Classic real-signal FFT via vDSP's zrip routines (Hann-windowed, split-complex),
/// replacing SOUND.CPP's hand-rolled FFT. Bass/treble band scaling (0.2x / 5x)
/// mirrors the ratio Geiss's changelog describes ("scaled bass by 0.2x, treble by
/// 5x") as a starting point — expect to retune both once effects are on screen.
final class FFTAnalyzer {
    private let log2n: vDSP_Length
    private let fftSize: Int
    private let fftSetup: FFTSetup
    private var realp: [Float]
    private var imagp: [Float]
    private var window: [Float]

    private let bassRangeHz: ClosedRange<Float> = 20...250
    private let trebleRangeHz: ClosedRange<Float> = 2_000...8_000

    init(log2n: Int = 11) { // 2048 samples per analysis window
        self.log2n = vDSP_Length(log2n)
        self.fftSize = 1 << log2n
        guard let setup = vDSP_create_fftsetup(self.log2n, FFTRadix(kFFTRadix2)) else {
            fatalError("vDSP_create_fftsetup failed for log2n=\(log2n)")
        }
        self.fftSetup = setup
        self.realp = [Float](repeating: 0, count: fftSize / 2)
        self.imagp = [Float](repeating: 0, count: fftSize / 2)
        self.window = [Float](repeating: 0, count: fftSize)
        vDSP_hann_window(&window, vDSP_Length(fftSize), Int32(vDSP_HANN_NORM))
    }

    deinit {
        vDSP_destroy_fftsetup(fftSetup)
    }

    /// `pcm` should be mono float samples in [-1, 1]; shorter/longer buffers are
    /// zero-padded/truncated to the analyzer's fixed FFT size.
    func analyze(pcm: [Float], sampleRate: Float) -> FFTResult {
        var samples = [Float](repeating: 0, count: fftSize)
        let n = min(pcm.count, fftSize)
        if n > 0 {
            samples.replaceSubrange(0..<n, with: pcm.suffix(n))
        }
        vDSP_vmul(samples, 1, window, 1, &samples, 1, vDSP_Length(fftSize))

        var magnitudes = [Float](repeating: 0, count: fftSize / 2)
        realp.withUnsafeMutableBufferPointer { realPtr in
            imagp.withUnsafeMutableBufferPointer { imagPtr in
                var splitComplex = DSPSplitComplex(realp: realPtr.baseAddress!, imagp: imagPtr.baseAddress!)
                samples.withUnsafeBufferPointer { samplePtr in
                    samplePtr.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: fftSize / 2) { complexPtr in
                        vDSP_ctoz(complexPtr, 2, &splitComplex, 1, vDSP_Length(fftSize / 2))
                    }
                }
                vDSP_fft_zrip(fftSetup, &splitComplex, 1, log2n, FFTDirection(FFT_FORWARD))
                vDSP_zvmags(&splitComplex, 1, &magnitudes, 1, vDSP_Length(fftSize / 2))
            }
        }

        var scale = Float(1.0) / Float(fftSize * fftSize)
        vDSP_vsmul(magnitudes, 1, &scale, &magnitudes, 1, vDSP_Length(magnitudes.count))

        let binHz = sampleRate / Float(fftSize)
        let bass = averageMagnitude(magnitudes, range: bassRangeHz, binHz: binHz) * 0.2
        let treble = averageMagnitude(magnitudes, range: trebleRangeHz, binHz: binHz) * 5.0

        return FFTResult(spectrum: magnitudes, bass: bass, treble: treble)
    }

    private func averageMagnitude(_ magnitudes: [Float], range: ClosedRange<Float>, binHz: Float) -> Float {
        guard binHz > 0, !magnitudes.isEmpty else { return 0 }
        let lowBin = max(1, Int(range.lowerBound / binHz))
        let highBin = min(magnitudes.count - 1, Int(range.upperBound / binHz))
        guard lowBin <= highBin else { return 0 }
        var sum: Float = 0
        for i in lowBin...highBin { sum += magnitudes[i] }
        return sqrt(sum / Float(highBin - lowBin + 1))
    }
}
