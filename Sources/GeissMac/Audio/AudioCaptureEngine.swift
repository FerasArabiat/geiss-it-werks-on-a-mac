import ScreenCaptureKit
import AVFAudio
import Accelerate

/// Captures system audio output — replacing SOUND.CPP's DirectSound loopback
/// capture ("Stereo Mix") — through one of two paths:
///
/// - The packaged app (macOS 14.4+) uses a Core Audio process tap
///   (SystemAudioTap), which needs only the "System Audio Recording Only"
///   permission. The Info.plist's NSAudioCaptureUsageDescription is what
///   makes the system able to ask for it, so this path requires the bundle.
/// - `swift run` (no Info.plist), or a tap that can't be created, uses
///   ScreenCaptureKit's audio-capture path, following Apple's "Capturing
///   screen content in macOS" sample (CaptureEngine.swift / PowerMeter.swift).
///   On macOS 15+ that also brings the recurring "bypass the private window
///   picker" prompt, which is why the app prefers the tap.
///
/// ScreenCaptureKit details:
/// Requires Screen Recording permission (TCC) even though no video is captured —
/// the first call to SCShareableContent triggers the system prompt; if denied,
/// `start()` throws and we log rather than crash. Video is configured at 2x2 /
/// ~1fps purely to satisfy SCContentFilter's requirement of a display target;
/// we never read the video output.
///
/// Fallback considered and rejected as the *primary* path (but worth keeping as a
/// documented alternative): a virtual audio device like BlackHole. ScreenCaptureKit
/// avoids the "ask the user to install something" step, which matters more now that
/// we're not also carrying legacy-OS support that might lack ScreenCaptureKit audio.
final class AudioCaptureEngine: NSObject {
    var onAnalysis: ((AudioAnalysis) -> Void)?
    /// Called if capture can't start — usually Screen Recording permission.
    var onStartFailed: (() -> Void)?

    private var stream: SCStream?
    /// A SystemAudioTap when that path is active (typed loosely: the class
    /// needs macOS 14.4).
    private var tap: AnyObject?
    private let streamOutput = AudioStreamOutput()
    private let sampleQueue = DispatchQueue(label: "com.geissmac.audio-samples")
    private let analyzer = FFTAnalyzer()
    private let beatDetector = BeatDetector()
    private let waveformWindowSize = 2048
    private var waveformAccumulator: [Float] = []
    private var waveformAccumulatorR: [Float] = []

    func start() {
        if #available(macOS 14.4, *), Bundle.main.object(forInfoDictionaryKey: "NSAudioCaptureUsageDescription") != nil {
            let tap = SystemAudioTap()
            do {
                try tap.start { [weak self] buffer in self?.process(buffer) }
                self.tap = tap
                print("GeissMac: system audio tap started.")
                return
            } catch {
                print("GeissMac: system audio tap unavailable (\(error)); falling back to ScreenCaptureKit.")
            }
        }
        startScreenCaptureKit()
    }

    private func startScreenCaptureKit() {
        streamOutput.onPCMBuffer = { [weak self] pcmBuffer in
            self?.process(pcmBuffer)
        }

        Task {
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
                guard let display = content.displays.first else {
                    print("GeissMac: no capturable display found; system audio tap not started.")
                    return
                }

                let filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])
                let config = SCStreamConfiguration()
                config.capturesAudio = true
                config.excludesCurrentProcessAudio = true
                config.width = 2
                config.height = 2
                config.minimumFrameInterval = CMTime(value: 1, timescale: 1)

                let stream = SCStream(filter: filter, configuration: config, delegate: streamOutput)
                self.stream = stream
                try stream.addStreamOutput(streamOutput, type: .audio, sampleHandlerQueue: sampleQueue)
                try await stream.startCapture()
                print("GeissMac: system audio capture started (display: \(display.displayID)).")
            } catch {
                print("""
                GeissMac: failed to start system audio capture — \(error.localizedDescription)
                If this is the first run, check System Settings > Privacy & Security > \
                Screen Recording and grant access, then relaunch.
                """)
                self.onStartFailed?()
            }
        }
    }

    func stop() {
        if #available(macOS 14.4, *), let tap = tap as? SystemAudioTap {
            tap.stop()
            self.tap = nil
        }
        Task { try? await stream?.stopCapture() }
    }

    private func process(_ pcmBuffer: AVAudioPCMBuffer) {
        guard let channelData = pcmBuffer.floatChannelData else { return }
        let frameCount = Int(pcmBuffer.frameLength)
        guard frameCount > 0 else { return }

        // ScreenCaptureKit delivers deinterleaved channels; a tap's format may
        // be interleaved (channelData[0] then holds every channel, strided).
        let channels = Int(pcmBuffer.format.channelCount)
        let samples: [Float]
        let samplesR: [Float]
        if pcmBuffer.format.isInterleaved {
            let interleaved = channelData[0]
            samples = (0..<frameCount).map { interleaved[$0 * channels] }
            samplesR = channels >= 2 ? (0..<frameCount).map { interleaved[$0 * channels + 1] } : samples
        } else {
            samples = Array(UnsafeBufferPointer(start: channelData[0], count: frameCount))
            samplesR = channels >= 2 ? Array(UnsafeBufferPointer(start: channelData[1], count: frameCount)) : samples
        }
        waveformAccumulator.append(contentsOf: samples)
        if waveformAccumulator.count > waveformWindowSize {
            waveformAccumulator.removeFirst(waveformAccumulator.count - waveformWindowSize)
        }

        // Right channel for the stereo waveform styles; mono input duplicates
        // the left, so those styles degrade to a flat diagonal line.
        waveformAccumulatorR.append(contentsOf: samplesR)
        if waveformAccumulatorR.count > waveformWindowSize {
            waveformAccumulatorR.removeFirst(waveformAccumulatorR.count - waveformWindowSize)
        }

        let fft = analyzer.analyze(pcm: waveformAccumulator, sampleRate: Float(pcmBuffer.format.sampleRate))
        var rms: Float = 0
        vDSP_rmsqv(waveformAccumulator, 1, &rms, vDSP_Length(waveformAccumulator.count))
        let beat = beatDetector.detectBeat(bassLevel: fft.bass)

        callbackCount += 1
        if callbackCount % 100 == 0 {
            print("GeissMac: audio flowing — \(callbackCount) callbacks, bass=\(fft.bass), treble=\(fft.treble), beat=\(beat)")
        }

        onAnalysis?(AudioAnalysis(
            waveform: waveformAccumulator,
            waveformR: waveformAccumulatorR,
            rms: rms,
            sampleRate: Float(pcmBuffer.format.sampleRate),
            timestamp: ProcessInfo.processInfo.systemUptime,
            spectrum: fft.spectrum,
            bassLevel: fft.bass,
            trebleLevel: fft.treble,
            beatDetected: beat
        ))
    }

    private var callbackCount = 0
}

/// Per-frame audio summary handed to the renderer — the modern equivalent of
/// GetWaveData()'s output in SOUND.CPP.
struct AudioAnalysis {
    var waveform: [Float] = []       // recent PCM window (left channel), for oscilloscope-style modes
    var waveformR: [Float] = []      // right channel — dual-channel/vectorscope waveform styles
    var rms: Float = 0               // of `waveform`
    var sampleRate: Float = 48000
    /// `ProcessInfo.systemUptime` when captured — lets the renderer notice
    /// when buffers stop arriving (nothing playing) rather than keep reading
    /// the last one.
    var timestamp: TimeInterval = 0
    var spectrum: [Float] = []       // FFT magnitude bins
    var bassLevel: Float = 0
    var trebleLevel: Float = 0
    var beatDetected: Bool = false
}

/// SCStreamOutput/SCStreamDelegate glue — converts CMSampleBuffers to
/// AVAudioPCMBuffer using the same `withAudioBufferList` pattern as Apple's
/// own sample, then hands it off. Kept separate from AudioCaptureEngine
/// because SCStream requires an NSObject-conforming output/delegate.
private final class AudioStreamOutput: NSObject, SCStreamOutput, SCStreamDelegate {
    var onPCMBuffer: ((AVAudioPCMBuffer) -> Void)?

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of outputType: SCStreamOutputType) {
        guard outputType == .audio, sampleBuffer.isValid else { return }
        try? sampleBuffer.withAudioBufferList { audioBufferList, _ in
            guard let description = sampleBuffer.formatDescription?.audioStreamBasicDescription,
                  let format = AVAudioFormat(standardFormatWithSampleRate: description.mSampleRate, channels: description.mChannelsPerFrame),
                  let pcmBuffer = AVAudioPCMBuffer(pcmFormat: format, bufferListNoCopy: audioBufferList.unsafePointer)
            else { return }
            onPCMBuffer?(pcmBuffer)
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        print("GeissMac: audio stream stopped unexpectedly — \(error.localizedDescription)")
    }
}
