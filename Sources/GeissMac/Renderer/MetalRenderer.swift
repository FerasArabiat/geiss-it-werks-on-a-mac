import Metal
import MetalKit
import simd

/// Must stay layout-compatible with WaveformUniforms in Shaders.metal.
private struct WaveformUniforms {
    var color: SIMD4<Float>
    var centerPx: SIMD2<Float>
    var resolution: SIMD2<Float>
    var amplitudePx: Float
    var perpendicularOffsetPx: Float
    var halfThicknessPx: Float
    var baseRadiusPx: Float
    var sampleCount: UInt32
    var style: UInt32
    var rotation: Float
    var _padding: Float = 0
}

/// Must stay layout-compatible with WarpUniforms in Shaders.metal.
private struct WarpUniforms {
    var centerPx: SIMD2<Float>
    var resolution: SIMD2<Float>
    var rotationCos: Float
    var rotationSin: Float
    var damping: Float
    var weightsum: Float
    var protectiveFactor: Float
    var f1: Float
    var f2: Float
    var f3: Float
    var mode: UInt32
    var centerDwindle: Float
    var nativePixelScale: Float
    var slideOffsetPx: SIMD2<Float>
}

/// Must stay layout-compatible with VortexPoint in Shaders.metal.
private struct VortexPoint {
    var position: SIMD2<Float>
    var direction: SIMD2<Float>
    var type: Int32
    var _padding: Int32 = 0
}

/// GPU reimplementation of Geiss's CPU rasterizer (originally proc_map.cpp's
/// MMX/Cyrix inline asm loops, driven by Effects.h/main.cpp's per-mode
/// parameter tables). See Shaders.metal's warp_fragment doc comment for how
/// the feedback-zoom transform itself works.
///
/// Each frame: warp the previous feedback texture into the other one (with
/// decay), stamp the current audio waveform additively on top of that, then
/// present the result to the screen. That texture becomes next frame's
/// "previous" — the ping-ponging is what makes the trails self-sustaining.
final class MetalRenderer {
    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue

    private var wavePipelineState: MTLRenderPipelineState?
    private var warpPipelineState: MTLRenderPipelineState?
    private var presentPipelineState: MTLRenderPipelineState?
    private var hudPipelineState: MTLRenderPipelineState?
    private var titleStampPipelineState: MTLRenderPipelineState?
    private lazy var popupTextures = PopupTextTextures(device: device)
    /// Each popup is stamped into this renderer's trails exactly once.
    private var stampedPopupIDs: Set<Int> = []
    private lazy var hudLeft = HUDOverlay(device: device)
    private lazy var hudRight = HUDOverlay(device: device)
    private var lastFrameTime: TimeInterval = 0
    /// Smoothed like the original's (`fps*0.95 + new*0.05`, main.cpp:2032).
    private var measuredFPS: Float = 0
    private var spritePipelines: [SpriteBlend: MTLRenderPipelineState] = [:]
    private var sampler: MTLSamplerState?

    private var sampleBuffer: MTLBuffer?
    private var sampleBufferR: MTLBuffer?
    private let maxSamples = 4096

    private var particlePositionBuffer: MTLBuffer? // xy = pixel position, z = point size, w = Sprite.Shape
    private var particleColorBuffer: MTLBuffer?
    /// Worst case is every overlay on at once: GRID ~550, SOLAR ~100 plus
    /// mode 1's 500 burst, BAR 150, CHASERS 40, DOTS 20, SHADE 4, NUCLIDE 7.
    private let maxParticles = 4096
    private var lastModeSwitchCount = -1

    /// Ping-pong feedback textures; `feedbackTextures[writeIndex]` is this
    /// frame's render target, `feedbackTextures[1 - writeIndex]` is last
    /// frame's result (this frame's warp source).
    private var feedbackTextures: [MTLTexture?] = [nil, nil]
    private var writeIndex = 0
    // Deliberately an 8-bit UNorm format, not a float format: this hard-clamps
    // every write to [0,1] via the GPU's blend/ROP hardware, matching the
    // original's actual accumulation buffer (VS1, `unsigned char` per
    // channel, hard 0-255 clamp on every write). A float format was tried
    // first and is what actually caused the "washes out to flat white" bug —
    // it let brightness accumulate unbounded instead of saturating the way
    // an 8-bit buffer naturally does.
    private let feedbackPixelFormat: MTLPixelFormat = .bgra8Unorm
    private var dampingSmoothed: Float = 1.0

    // MARK: - Color

    /// The original's `g_power_smoothed`, for "sync color to sound".
    private var soundBands = SoundBands()

    /// The waveform/effect color (see SceneColor), clamped to 0-1. `base`
    /// stands in for the original's 0-255 brightness — the port's 0-1
    /// loudness, since the formulas are ratios and products that don't
    /// depend on that scale.
    private func waveColor(base: Float, effectState: EffectState) -> SIMD4<Float> {
        let t = effectState.colorTime
        let c = effectState.colorMode == .sound
            ? SceneColor.sound(bands: soundBands.smoothed, t: t, base: base)
            : SceneColor.time(t: t, base: base)
        let clamped = c.clamped(lowerBound: SIMD3(repeating: 0), upperBound: SIMD3(repeating: 1))
        return SIMD4(clamped, 1)
    }

    // MARK: - 8-bit look

    /// 256×1 RGBA: the palette the present pass looks each pixel up in.
    private var paletteTexture: MTLTexture?
    private var paletteFrom: [SIMD4<Float>] = []
    private var paletteTo: [SIMD4<Float>] = []
    private var paletteFadeStart: TimeInterval = 0
    private var shownPaletteSerial = -1
    private var paletteFading = false

    /// PutPalette's crossfade from the previous palette to the new one, over
    /// 9 frames at 30fps (it counted 18 blends down two at a time), bytes
    /// truncated as in the original.
    private func updatePalette(_ effectState: EffectState) {
        let now = ProcessInfo.processInfo.systemUptime
        if effectState.paletteSerial != shownPaletteSerial {
            let table = effectState.palette.table().map { SIMD4<Float>($0) }
            paletteFrom = shownPaletteSerial < 0 ? table : paletteTo
            paletteTo = table
            paletteFadeStart = now
            shownPaletteSerial = effectState.paletteSerial
            paletteFading = true
        }
        guard paletteFading, let paletteTexture else { return }
        let old = Float(max(0, 1 - (now - paletteFadeStart) * 30 / 9))
        let blended = zip(paletteFrom, paletteTo).map { from, to in
            SIMD4<UInt8>(from * old + to * (1 - old), rounding: .towardZero)
        }
        blended.withUnsafeBytes { bytes in
            paletteTexture.replace(region: MTLRegionMake2D(0, 0, 256, 1), mipmapLevel: 0,
                                   withBytes: bytes.baseAddress!, bytesPerRow: 256 * 4)
        }
        if old == 0 { paletteFading = false }
    }

    // MARK: - Waveform sampling

    /// The original's per-style audio slice (main.cpp's RenderWave): one
    /// 44.1kHz sample per 2 original pixels along the line — ~7ms across
    /// the screen at any resolution, since it interpolates the buffer at
    /// high res to keep that — low-passed along the line. Drawing the whole
    /// 2048-sample capture window instead showed ~6x more audio, a dense
    /// jittery scribble.
    private func originalWaveSamples(style: Int, audio: AudioAnalysis, nativeSize: SIMD2<Float>) -> (left: [Float], right: [Float]) {
        let rate = audio.sampleRate / 44100
        // Samples at 44.1kHz, and the per-sample weight on the previous
        // value of RenderWave's along-the-line smoothing.
        let samplesAt44k: Float
        let keep: Float
        switch style {
        case 3, 4:
            samplesAt44k = nativeSize.y / 2 // one per 2 rows
            keep = 0.81                     // `prev*0.9 + new*0.1` per pixel, 2 pixels per sample
        case 5:
            samplesAt44k = 157              // 314 ring points, 2 per sample
            keep = 0.25                     // `rad*0.5 + new*0.5` per point
        case 6:
            samplesAt44k = 314
            keep = 0.5
        default:
            samplesAt44k = nativeSize.x / 2
            keep = 0.81
        }
        // Radial only: extra samples past the ring's end to crossfade its
        // start into, so it closes without a seam (WAVE_5_BLEND_RANGE,
        // main.cpp:9307-9311).
        let ringBlend = style == 5 ? Int(25 * rate) : 0
        let available = min(audio.waveform.count, audio.waveformR.count)
        let count = min(Int(samplesAt44k * rate), available - ringBlend, maxSamples)
        guard count > 1 else { return ([], []) }

        func prepare(_ raw: [Float]) -> [Float] {
            var s = Array(raw.suffix(count + ringBlend))
            // `0.8*s[i] + 0.2*s[i+1]` pre-filter (main.cpp:8233).
            for i in 0..<(s.count - 1) { s[i] = 0.8 * s[i] + 0.2 * s[i + 1] }
            for i in 0..<ringBlend {
                let amt = Float(i) / Float(ringBlend)
                s[i] = s[i] * amt + s[count + i] * (1 - amt)
            }
            var z = s[0]
            return (0..<count).map { i in
                z = z * keep + s[i] * (1 - keep)
                return z
            }
        }
        return (prepare(audio.waveform), prepare(audio.waveformR))
    }

    // MARK: - Clocks and overlay effects

    /// The original's `intframe` (`main.cpp:5436`: `intframe++`, a plain
    /// per-frame counter) — SOLAR's density oscillator, NUCLIDE's color,
    /// GRID, the vectorscope spin.
    private var rawFrameCounter: Float = 0

    /// The original's `floatframe` (`main.cpp:5435`: `floatframe += 1.6 *
    /// min(1.0, 47.0/fps)` — capped so it can't advance faster than 75.2
    /// units/sec once fps exceeds 47) — SHADE, CHASERS, BAR, DOTS.
    private var floatFrameCounter: Float = 0

    private lazy var overlayEffects = OverlayEffects(colorFrequencies: SceneColor.frequencies)

    /// The original's per-mode `modeInfo[z].center_dwindle`
    /// (main.cpp:4009-4242), applied by Diminish_Center in the warp shader.
    private func centerDwindle(forMode mode: Int) -> Float {
        switch Modes.original(mode) {
        case 3, 5: return 0.99
        case 4, 13, 14, 16, 20...23: return 0.98
        case 7, 9: return 0.985
        case 8: return 0.96
        case 12: return 0.915
        default: return 1.0
        }
    }

    /// The original's `weightsum_res_adjusted`, its per-frame fade: 256 ×
    /// 253/256 at its 640x480 reference (main.cpp:4596-4607), except mode 12,
    /// whose init sets `weightsum *= 0.98` first (256 → 250 → 247). Replaced
    /// the port's hand-tuned per-mode decays (0.90-0.98) on 2026-09-25: those
    /// faded ~8x faster per frame, which kept SOLAR sparks and trails from
    /// lingering and growing as they did in the original.
    private func originalWeightsum(forMode mode: Int) -> Float {
        Modes.original(mode) == 12 ? 247 : 253
    }

    /// Flips every frame; smooth60 applies the original's fade on alternate
    /// frames only.
    private var blendFrame = false

    init(device: MTLDevice) {
        self.device = device
        guard let queue = device.makeCommandQueue() else {
            fatalError("Failed to create a Metal command queue.")
        }
        self.commandQueue = queue
        self.sampleBuffer = device.makeBuffer(
            length: maxSamples * MemoryLayout<Float>.stride,
            options: .storageModeShared
        )
        self.sampleBufferR = device.makeBuffer(
            length: maxSamples * MemoryLayout<Float>.stride,
            options: .storageModeShared
        )
        self.particlePositionBuffer = device.makeBuffer(
            length: maxParticles * MemoryLayout<SIMD4<Float>>.stride,
            options: .storageModeShared
        )
        self.particleColorBuffer = device.makeBuffer(
            length: maxParticles * MemoryLayout<SIMD4<Float>>.stride,
            options: .storageModeShared
        )
        buildSampler()
        buildPipelines()
        let paletteDescriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: 256, height: 1, mipmapped: false)
        paletteDescriptor.usage = .shaderRead
        paletteTexture = device.makeTexture(descriptor: paletteDescriptor)
    }

    private func buildSampler() {
        let descriptor = MTLSamplerDescriptor()
        descriptor.minFilter = .linear
        descriptor.magFilter = .linear
        descriptor.sAddressMode = .repeat       // wraps horizontally, matching the original's X wraparound
        descriptor.tAddressMode = .clampToEdge  // original clamps Y away from the top/bottom rows
        sampler = device.makeSamplerState(descriptor: descriptor)
    }

    private func buildPipelines() {
        // The packaged .app carries Shaders.metal in Contents/Resources
        // (scripts/build-app.sh). SwiftPM's Bundle.module only works for
        // `swift run`: inside an .app it looks at the bundle root (which
        // breaks code signing) and then at this machine's build folder — so
        // it's only consulted when the main bundle has no copy.
        let shaderURL = Bundle.main.url(forResource: "Shaders", withExtension: "metal")
            ?? Bundle.module.url(forResource: "Shaders", withExtension: "metal")
        guard let shaderURL, let source = try? String(contentsOf: shaderURL, encoding: .utf8) else {
            print("GeissMac: could not locate/read Shaders.metal in the resource bundle.")
            return
        }
        guard let library = try? device.makeLibrary(source: source, options: nil) else {
            print("GeissMac: Shaders.metal failed to compile at runtime.")
            return
        }

        func makePipeline(vertex: String, fragment: String, pixelFormat: MTLPixelFormat, blendOperation: MTLBlendOperation?, destinationFactor: MTLBlendFactor = .one) -> MTLRenderPipelineState? {
            guard let vertexFn = library.makeFunction(name: vertex),
                  let fragmentFn = library.makeFunction(name: fragment) else {
                print("GeissMac: shader functions \(vertex)/\(fragment) not found.")
                return nil
            }
            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.vertexFunction = vertexFn
            descriptor.fragmentFunction = fragmentFn
            descriptor.colorAttachments[0].pixelFormat = pixelFormat
            if let blendOperation {
                let attachment = descriptor.colorAttachments[0]!
                attachment.isBlendingEnabled = true
                attachment.rgbBlendOperation = blendOperation
                attachment.alphaBlendOperation = blendOperation
                attachment.sourceRGBBlendFactor = .one
                attachment.sourceAlphaBlendFactor = .one
                attachment.destinationRGBBlendFactor = destinationFactor
                attachment.destinationAlphaBlendFactor = destinationFactor
            }
            do {
                return try device.makeRenderPipelineState(descriptor: descriptor)
            } catch {
                print("GeissMac: failed to build pipeline (\(vertex)/\(fragment)) — \(error)")
                return nil
            }
        }

        // Waveform stamps onto the feedback texture with MAX blending, not
        // additive — this matches the original's actual draw semantics
        // (main.cpp's RenderWave/GetWaveData: `if (VS1[offset] < r) VS1[offset]
        // = r`, a brighten-only overwrite), not an accumulating sum. Additive
        // blending was what caused the "washes out to flat white" bug: a
        // pixel re-touched by the line across many frames would
        // sum without bound instead of just staying capped at the brightest
        // value it was ever set to.
        wavePipelineState = makePipeline(vertex: "waveform_vertex", fragment: "waveform_fragment", pixelFormat: feedbackPixelFormat, blendOperation: .max)
        warpPipelineState = makePipeline(vertex: "fullscreen_vertex", fragment: "warp_fragment", pixelFormat: feedbackPixelFormat, blendOperation: nil)
        presentPipelineState = makePipeline(vertex: "fullscreen_vertex", fragment: "present_fragment", pixelFormat: .bgra8Unorm, blendOperation: nil)
        // Premultiplied alpha: HUDOverlay's CGContext output.
        hudPipelineState = makePipeline(vertex: "hud_vertex", fragment: "hud_fragment", pixelFormat: .bgra8Unorm, blendOperation: .add, destinationFactor: .oneMinusSourceAlpha)
        titleStampPipelineState = makePipeline(vertex: "hud_vertex", fragment: "title_stamp_fragment", pixelFormat: feedbackPixelFormat, blendOperation: nil)
        // One sprite pipeline per SpriteBlend, matching each overlay's pixel
        // math in the original. Additive is safe (unlike the old
        // float-texture washout) because the render target hard-clamps to
        // [0,1]. Screen: `src + dst*(1-src)`, which with src 0.4 is exactly
        // CHASERS' `255-(255-v)*0.6`.
        func spritePipeline(_ operation: MTLBlendOperation?, _ destination: MTLBlendFactor = .one) -> MTLRenderPipelineState? {
            makePipeline(vertex: "particle_vertex", fragment: "particle_fragment", pixelFormat: feedbackPixelFormat, blendOperation: operation, destinationFactor: destination)
        }
        spritePipelines[.add] = spritePipeline(.add)
        spritePipelines[.screen] = spritePipeline(.add, .oneMinusSourceColor)
        spritePipelines[.replace] = spritePipeline(nil)
        spritePipelines[.max] = spritePipeline(.max)
    }

    func resize(to size: CGSize) {
        guard size.width > 0, size.height > 0 else { return }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: feedbackPixelFormat,
            width: Int(size.width),
            height: Int(size.height),
            mipmapped: false
        )
        descriptor.usage = [.renderTarget, .shaderRead]
        descriptor.storageMode = .private
        feedbackTextures = [device.makeTexture(descriptor: descriptor), device.makeTexture(descriptor: descriptor)]
        writeIndex = 0
    }

    /// MTKView's `drawableSizeWillChange` delegate callback isn't reliably
    /// firing for the initial size in this app's window-setup path (confirmed
    /// by instrumenting — feedbackTextures stayed nil for hundreds of frames
    /// with no resize ever called), so don't depend on it alone. Instead,
    /// (re)allocate here whenever the drawable size doesn't match what we
    /// last sized for — cheap to check, and self-healing if the delegate
    /// callback never arrives or the view resizes without it firing either.
    private func ensureFeedbackTextures(matching drawableSize: CGSize) {
        let width = Int(drawableSize.width)
        let height = Int(drawableSize.height)
        guard width > 0, height > 0 else { return }
        if let existing = feedbackTextures[0], existing.width == width, existing.height == height {
            return
        }
        resize(to: drawableSize)
    }

    private var debugFrameCount = 0

    func renderFrame(into view: MTKView, effectState: EffectState, audio: AudioAnalysis, soundEmpty: Bool, hud: HUDText) {
        ensureFeedbackTextures(matching: view.drawableSize)

        debugFrameCount += 1
        if debugFrameCount % 120 == 1 {
            print("""
            GeissMac[render #\(debugFrameCount)]: warpPipeline=\(warpPipelineState != nil) \
            wavePipeline=\(wavePipelineState != nil) presentPipeline=\(presentPipelineState != nil) \
            sampler=\(sampler != nil) feedbackTex0=\(feedbackTextures[0] != nil) feedbackTex1=\(feedbackTextures[1] != nil) \
            drawable=\(view.currentDrawable != nil) waveformCount=\(audio.waveform.count)
            """)
        }
        guard let warpPipelineState, let wavePipelineState, let presentPipelineState,
              let sampler, let sampleBuffer, let sampleBufferR,
              let writeTexture = feedbackTextures[writeIndex],
              let readTexture = feedbackTextures[1 - writeIndex],
              let drawable = view.currentDrawable,
              let commandBuffer = commandQueue.makeCommandBuffer()
        else {
            if debugFrameCount % 120 == 1 { print("GeissMac[render #\(debugFrameCount)]: guard failed, skipping frame") }
            return
        }

        let resolution = SIMD2<Float>(Float(writeTexture.width), Float(writeTexture.height))
        let mode = UInt32(max(effectState.mode, 0))
        let motion = effectState.motion
        let protectiveFactor = resolution.x > 640 ? 640.0 / resolution.x : 1.0

        // Physical pixels per "original" pixel. The original's effects
        // (SOLAR/SHADE stamps, wave line weight, ring radius, center clamp)
        // are raw pixel constants tuned at ~640px wide; multiplying by this
        // keeps each one the same fraction of the screen on a modern
        // high-res/Retina display instead of shrinking ~5x.
        let nativePixelScale = resolution.x / 640.0

        // gXC/gYC — the zoom/rotation center (randomized per mode switch,
        // moved by the mouse; see EffectState.centerOffset). Shared by the
        // warp pass, the waveform, and the overlay effects, as in the original.
        let centerPx = resolution * 0.5 + effectState.centerOffset * nativePixelScale

        // Frame-rate handling. The original ran uncapped (EnforceMaxFPS is
        // never called), ~30fps on its hardware, and scaled its zoom/rotation
        // by 30/fps (`new_damping_temp`, main.cpp:4636-4637) — but its trail
        // decay, particle counts and `intframe` advance per frame. Here
        // classic30 is the reference; smooth60 scales every per-frame step
        // by `step` (0.5) to keep that speed; fast60 scales nothing, so
        // everything runs twice as fast. `originalFps` is the frame rate the
        // original's own fps-aware formulas should see.
        let step = effectState.frameRateMode.stepScale
        blendFrame.toggle()
        let fps = Float(effectState.frameRateMode.fps)
        let originalFps = fps * step

        // Beat-driven damping "kick": briefly softens the transform on a
        // detected beat, then eases back — the audio-reactive damping
        // Geiss's own changelog wanted to add but couldn't (licensing on the
        // original "spectral variance" approach). This is a fresh heuristic,
        // not a port.
        let dampingTarget: Float = audio.beatDetected ? 0.85 : 1.0
        dampingSmoothed += (dampingTarget - dampingSmoothed) * (1 - pow(0.85, step))
        rawFrameCounter += step
        soundBands.update(waveform: audio.waveform, sampleRate: audio.sampleRate, step: step)
        floatFrameCounter += 1.6 * min(1, 47 / originalFps) * step

        // --- Pass 1: warp the previous frame into this frame's texture ---
        let warpPass = MTLRenderPassDescriptor()
        warpPass.colorAttachments[0].texture = writeTexture
        warpPass.colorAttachments[0].loadAction = .dontCare
        warpPass.colorAttachments[0].storeAction = .store

        if let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: warpPass) {
            var uniforms = WarpUniforms(
                centerPx: centerPx,
                resolution: resolution,
                rotationCos: cos(motion.turn1),
                rotationSin: sin(motion.turn1),
                // Scaling damping by `step` moves each source sample only
                // that fraction of the way along this frame's transform —
                // half a zoom/rotation step per frame in smooth60. Exact for
                // small steps; curved modes' flows compose very slightly
                // differently from one full step.
                // motion.damping is the original's per-mode `new_damping`
                // (0.5 for its mode_motion_dampened modes).
                damping: dampingSmoothed * motion.damping * step,
                // The original's fade (see original_blend in Shaders.metal).
                // In smooth60 it's applied on every other frame, so trails
                // fade at the same real-time rate as at 30fps; the frames in
                // between just resample.
                weightsum: (step >= 1 || blendFrame) ? originalWeightsum(forMode: Int(mode)) : 0,
                protectiveFactor: protectiveFactor,
                f1: motion.f1,
                f2: motion.f2,
                f3: motion.f3,
                mode: mode,
                centerDwindle: pow(centerDwindle(forMode: Int(mode)), step),
                nativePixelScale: nativePixelScale,
                // Slide shift: a per-frame drift, added to the sample
                // position after damping, as the original offset its read
                // pointer.
                slideOffsetPx: effectState.slideOffset * nativePixelScale * step
            )
            // Mode 6's five random point sources; zero-filled for every other
            // mode so the shader's fixed-size buffer is always bound.
            let vortexSpecs = motion.vortexPoints.isEmpty
                ? Array(repeating: ModeMotion.VortexSpec(position: .zero, direction: .zero, type: 0), count: 5)
                : motion.vortexPoints
            var vortexPoints = vortexSpecs.map { spec in
                VortexPoint(position: spec.position * resolution, direction: spec.direction, type: spec.type)
            }

            encoder.setRenderPipelineState(warpPipelineState)
            encoder.setFragmentTexture(readTexture, index: 0)
            encoder.setFragmentSamplerState(sampler, index: 0)
            encoder.setFragmentBytes(&uniforms, length: MemoryLayout<WarpUniforms>.stride, index: 0)
            encoder.setFragmentBytes(&vortexPoints, length: MemoryLayout<VortexPoint>.stride * vortexPoints.count, index: 1)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            encoder.endEncoding()
        }

        // --- Pass 2: stamp the current waveform additively on top ---
        // Style numbering matches the original's (main.cpp's RenderWave):
        // 0 off, 1 horizontal scope, 2 dual-channel horizontal, 3 vertical,
        // 4 dual diagonal, 5 radial/circular, 6 vectorscope (L-vs-R
        // Lissajous). See Shaders.metal's waveform_vertex for the per-style
        // geometry; dual styles (2, 4) are two draws here.
        let waveformType = effectState.waveformType
        let waveSamples = waveformType == 0
            ? (left: [], right: [])
            : originalWaveSamples(style: waveformType, audio: audio, nativeSize: resolution / nativePixelScale)
        let sampleCount = waveSamples.left.count

        // Shared scene color — the waveform, trails, and SOLAR particles
        // (below) all draw from this one color, computed once per frame
        // regardless of whether the waveform itself is on, so SOLAR can use
        // it too. Scale injected brightness by actual loudness (RMS of this
        // frame's window) so quiet audio draws dim and loud audio bright —
        // a genuine "reacts to music" behavior the original didn't have
        // (its draw brightness was fixed; only geometry came from the
        // waveform). Safe to mix with MAX blending: a quiet frame's dim
        // write just won't exceed whatever brighter value is already there,
        // same as the original's own brighten-only semantics.
        let loudness = max(0.05, min(1.0, audio.rms * 8.0))
        let pulse: Float = audio.beatDetected ? 1.0 : 0.55
        let sceneColor = effectState.eightBit
            // The original's 8-bit branch: r = g = b = base; the palette colors it.
            ? SIMD4(loudness, loudness, loudness, 1) * pulse
            : waveColor(base: loudness, effectState: effectState) * pulse
        if effectState.eightBit { updatePalette(effectState) }

        if sampleCount > 1 {
            let contentsL = sampleBuffer.contents().bindMemory(to: Float.self, capacity: maxSamples)
            let contentsR = sampleBufferR.contents().bindMemory(to: Float.self, capacity: maxSamples)
            for i in 0..<sampleCount {
                contentsL[i] = waveSamples.left[i]
                contentsR[i] = waveSamples.right[i]
            }

            let wavePass = MTLRenderPassDescriptor()
            wavePass.colorAttachments[0].texture = writeTexture
            wavePass.colorAttachments[0].loadAction = .load
            wavePass.colorAttachments[0].storeAction = .store

            if let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: wavePass) {
                // Slow back-and-forth spin for the vectorscope (style 6):
                // the original's `ang = sinf(intframe*0.01)` (main.cpp:9342).
                let vectorscopeRotation = sin(rawFrameCounter * 0.01)

                encoder.setRenderPipelineState(wavePipelineState)
                encoder.setVertexBuffer(sampleBufferR, offset: 0, index: 2) // style 6 needs both channels at once

                // Base amplitude shared by every style; each style's own
                // multiplier is the original's local `fDiv` in RenderWave.
                // 'J'/'K' scale it by the original's volscale steps (×1.25).
                let amplitudePx = 0.35 * resolution.y * pow(1.25, Float(effectState.waveScaleStep))

                // Style 2: two horizontal scopes at `gYC ∓ FXH*0.12`, fDiv
                // 0.7 (main.cpp:9193). Style 4: two parallel 45° diagonals,
                // the right one shifted by `FXW-FXH`, fDiv 0.9
                // (main.cpp:9259-9271). Style 5 fDiv 0.7, style 6 fDiv 1.2.
                let draws: [(style: UInt32, buffer: MTLBuffer, offsetPx: Float, amplitudeScale: Float)]
                switch waveformType {
                case 2: draws = [(1, sampleBuffer, -0.12 * resolution.y, 0.7), (1, sampleBufferR, 0.12 * resolution.y, 0.7)]
                case 4: draws = [(4, sampleBuffer, 0, 0.9), (4, sampleBufferR, resolution.x - resolution.y, 0.9)]
                case 5: draws = [(5, sampleBuffer, 0, 0.7)]
                case 6: draws = [(6, sampleBuffer, 0, 1.2)]
                default: draws = [(UInt32(waveformType), sampleBuffer, 0, 1)]
                }

                for draw in draws {
                    var waveUniforms = WaveformUniforms(
                        color: sceneColor,
                        centerPx: centerPx,
                        resolution: resolution,
                        amplitudePx: amplitudePx * draw.amplitudeScale,
                        perpendicularOffsetPx: draw.offsetPx,
                        // 1 original (640-wide) pixel thick.
                        halfThicknessPx: max(0.5, 0.5 * nativePixelScale),
                        // `base_rad = FXW/640 * 60` (main.cpp:9304).
                        baseRadiusPx: 60 * nativePixelScale,
                        sampleCount: UInt32(sampleCount),
                        style: draw.style,
                        rotation: Float(vectorscopeRotation)
                    )
                    encoder.setVertexBuffer(draw.buffer, offset: 0, index: 0)
                    encoder.setVertexBytes(&waveUniforms, length: MemoryLayout<WaveformUniforms>.stride, index: 1)
                    encoder.setFragmentBytes(&waveUniforms, length: MemoryLayout<WaveformUniforms>.stride, index: 1)
                    encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: sampleCount * 2)
                }
                encoder.endEncoding()
            }
        }

        // --- Pass 2.5: overlay effects (OverlayEffects.swift) ---
        let enteredMode = effectState.modeSwitchCount != lastModeSwitchCount
        lastModeSwitchCount = effectState.modeSwitchCount
        let batches = overlayEffects.batches(for: OverlayFrame(
            centerPx: centerPx,
            resolution: resolution,
            nativePixelScale: nativePixelScale,
            step: step,
            originalFps: originalFps,
            intframe: rawFrameCounter,
            floatframe: floatFrameCounter,
            sceneColor: sceneColor,
            mode: effectState.mode,
            enteredMode: enteredMode,
            soundEmpty: soundEmpty
        ), state: effectState)

        if !batches.isEmpty, let particlePositionBuffer, let particleColorBuffer {
            let positions = particlePositionBuffer.contents().bindMemory(to: SIMD4<Float>.self, capacity: maxParticles)
            let colors = particleColorBuffer.contents().bindMemory(to: SIMD4<Float>.self, capacity: maxParticles)
            var draws: [(blend: SpriteBlend, start: Int, count: Int)] = []
            var written = 0
            for batch in batches {
                let count = min(batch.sprites.count, maxParticles - written)
                guard count > 0 else { break }
                for (i, sprite) in batch.sprites.prefix(count).enumerated() {
                    positions[written + i] = SIMD4(sprite.position.x, sprite.position.y, sprite.size, sprite.shape.rawValue)
                    colors[written + i] = sprite.color
                }
                draws.append((batch.blend, written, count))
                written += count
            }

            let particlePass = MTLRenderPassDescriptor()
            particlePass.colorAttachments[0].texture = writeTexture
            particlePass.colorAttachments[0].loadAction = .load
            particlePass.colorAttachments[0].storeAction = .store

            if let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: particlePass) {
                var particleResolution = resolution
                encoder.setVertexBuffer(particlePositionBuffer, offset: 0, index: 0)
                encoder.setVertexBuffer(particleColorBuffer, offset: 0, index: 1)
                encoder.setVertexBytes(&particleResolution, length: MemoryLayout<SIMD2<Float>>.stride, index: 2)
                for draw in draws {
                    guard let pipeline = spritePipelines[draw.blend] else { continue }
                    encoder.setRenderPipelineState(pipeline)
                    encoder.drawPrimitives(type: .point, vertexStart: draw.start, vertexCount: draw.count)
                }
                encoder.endEncoding()
            }
        }

        // --- Text popups (song title, clock): placed in the free space,
        // overlaid while their time runs, then stamped once into the trails
        // (see TextPopup) ---
        let now = ProcessInfo.processInfo.systemUptime
        var popupOverlays: [(texture: MTLTexture, rect: SIMD4<Float>)] = []
        stampedPopupIDs.formIntersection(hud.popups.map(\.id))
        for popup in hud.popups {
            guard let texture = popupTextures.texture(for: popup.text, nativePixelScale: nativePixelScale) else { continue }
            let size = SIMD2<Float>(Float(texture.width), Float(texture.height))
            let origin = popup.position * simd_max(resolution - size, .zero)
            let rect = SIMD4<Float>(origin.x, origin.y, size.x, size.y)
            if now - popup.shownAt < TextPopup.duration {
                popupOverlays.append((texture, rect))
            } else if !stampedPopupIDs.contains(popup.id), let titleStampPipelineState {
                stampedPopupIDs.insert(popup.id)
                let stampPass = MTLRenderPassDescriptor()
                stampPass.colorAttachments[0].texture = writeTexture
                stampPass.colorAttachments[0].loadAction = .load
                stampPass.colorAttachments[0].storeAction = .store
                if let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: stampPass) {
                    encoder.setRenderPipelineState(titleStampPipelineState)
                    encoder.setFragmentSamplerState(sampler, index: 0)
                    drawQuad(encoder, texture, rect: rect, resolution: resolution, fragmentColor: popup.stampColor)
                    encoder.endEncoding()
                }
            }
        }

        // --- Pass 3: present the result to the screen ---
        if let passDescriptor = view.currentRenderPassDescriptor,
           let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: passDescriptor) {
            encoder.setRenderPipelineState(presentPipelineState)
            encoder.setFragmentTexture(writeTexture, index: 0)
            encoder.setFragmentTexture(paletteTexture, index: 1)
            encoder.setFragmentSamplerState(sampler, index: 0)
            var eightBit: UInt32 = effectState.eightBit ? 1 : 0
            encoder.setFragmentBytes(&eightBit, length: MemoryLayout<UInt32>.stride, index: 0)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)

            // Popup overlays: RGB(20,20,20) shadow 1 original pixel
            // down-right, then RGB(225,225,225) text (video.h:214-225).
            if !popupOverlays.isEmpty, let hudPipelineState {
                encoder.setRenderPipelineState(hudPipelineState)
                for overlay in popupOverlays {
                    let shadowRect = overlay.rect + SIMD4(nativePixelScale, nativePixelScale, 0, 0)
                    drawQuad(encoder, overlay.texture, rect: shadowRect, resolution: resolution, fragmentColor: SIMD4(20 / 255, 20 / 255, 20 / 255, 1))
                    drawQuad(encoder, overlay.texture, rect: overlay.rect, resolution: resolution, fragmentColor: SIMD4(225 / 255, 225 / 255, 225 / 255, 1))
                }
            }

            // On-screen text, over the final image only (never into the trails).
            let dt = Float(now - lastFrameTime)
            lastFrameTime = now
            if dt > 0 && dt < 1 {
                measuredFPS = measuredFPS == 0 ? 1 / dt : measuredFPS * 0.95 + 0.05 / dt
            }
            // A message takes the line; fps shows when there isn't one.
            let fpsLine = hud.showFPS ? String(format: "fps: %3.1f", measuredFPS) : nil
            if let hudPipelineState {
                let left = hudLeft.texture(message: hud.message ?? fpsLine, helpColumns: hud.helpLeft.map { [$0] } ?? [],
                                           indent: 20, nativePixelScale: nativePixelScale)
                let right = hudRight.texture(message: nil, helpColumns: hud.helpRight.map { [$0] } ?? [],
                                             indent: 0, nativePixelScale: nativePixelScale)
                encoder.setRenderPipelineState(hudPipelineState)
                for (text, x) in [(left, Float(0)), (right, resolution.x - Float(right?.width ?? 0))] {
                    guard let text else { continue }
                    drawQuad(encoder, text, rect: SIMD4(x, 0, Float(text.width), Float(text.height)),
                             resolution: resolution, fragmentColor: SIMD4(repeating: 1))
                }
            }
            encoder.endEncoding()
        }

        commandBuffer.present(drawable)
        commandBuffer.commit()

        writeIndex = 1 - writeIndex
    }

    /// A texture drawn 1:1 into a pixel rect (hud_vertex); `fragmentColor`
    /// is the HUD tint or the title stamp color.
    private func drawQuad(_ encoder: MTLRenderCommandEncoder, _ texture: MTLTexture, rect: SIMD4<Float>,
                          resolution: SIMD2<Float>, fragmentColor: SIMD4<Float>) {
        var rect = rect
        var resolution = resolution
        var color = fragmentColor
        encoder.setVertexBytes(&rect, length: MemoryLayout<SIMD4<Float>>.stride, index: 0)
        encoder.setVertexBytes(&resolution, length: MemoryLayout<SIMD2<Float>>.stride, index: 1)
        encoder.setFragmentBytes(&color, length: MemoryLayout<SIMD4<Float>>.stride, index: 0)
        encoder.setFragmentTexture(texture, index: 0)
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
    }
}
