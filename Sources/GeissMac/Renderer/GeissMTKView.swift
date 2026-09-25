import MetalKit
import AppKit

/// MTKView subclass: owns the MetalRenderer for this screen and forwards raw
/// NSEvents to the shared InputController. One instance per display.
final class GeissMTKView: MTKView, MTKViewDelegate {
    private let renderer: MetalRenderer
    private let input: InputController
    private let titlePrefix: String
    private var lastDisplayedTitle: String?

    /// Fullscreen views show a blank cursor over themselves.
    var hidesCursor = false {
        didSet { window?.invalidateCursorRects(for: self) }
    }

    private static let blankCursor = NSCursor(image: NSImage(size: NSSize(width: 1, height: 1)), hotSpot: .zero)

    override func resetCursorRects() {
        if hidesCursor {
            addCursorRect(bounds, cursor: Self.blankCursor)
        } else {
            super.resetCursorRects()
        }
    }

    init(frame: CGRect, input: InputController, titlePrefix: String) {
        self.input = input
        self.titlePrefix = titlePrefix
        guard let device = MTLCreateSystemDefaultDevice() else {
            fatalError("Metal is required — Apple Silicon GPUs all support it, this should never fail.")
        }
        self.renderer = MetalRenderer(device: device)
        super.init(frame: frame, device: device)
        self.delegate = self
        self.preferredFramesPerSecond = EffectState().frameRateMode.fps
        self.colorPixelFormat = .bgra8Unorm
        // Deliberately not pure black, so "the view is rendering but nothing
        // was drawn" is visually distinct from "nothing is happening at all".
        self.clearColor = MTLClearColor(red: 0.03, green: 0.03, blue: 0.05, alpha: 1.0)
    }

    required init(coder: NSCoder) { fatalError("unused") }

    // MARK: MTKViewDelegate

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        renderer.resize(to: size)
    }

    func draw(in view: MTKView) {
        input.tick()
        updateWindowTitle()
        let effectState = input.currentEffectState
        // Synced here rather than in the key handler so every screen's view
        // follows the toggle, not just the one that received the keypress.
        if preferredFramesPerSecond != effectState.frameRateMode.fps {
            preferredFramesPerSecond = effectState.frameRateMode.fps
        }
        renderer.renderFrame(into: view, effectState: effectState, audio: input.latestAudio, soundEmpty: input.soundEmpty, hud: input.hudText())
    }

    /// Shows the in-progress two-digit mode entry (or the current mode and
    /// effects) in the title bar — useful in windowed mode alongside the
    /// on-screen HUD text (HUDOverlay), which is all fullscreen has.
    private func updateWindowTitle() {
        let title = "\(titlePrefix) — \(input.titleStatus())"
        guard title != lastDisplayedTitle else { return }
        lastDisplayedTitle = title
        window?.title = title
    }

    // MARK: Input passthrough — see Input/InputController.swift for the mapping
    // from raw events to Geiss's original mode/palette/effect controls.

    override func keyDown(with event: NSEvent) {
        // ⌘-combinations belong to the menu (⌘Q), not to Geiss's letter keys.
        if event.modifierFlags.contains(.command) {
            super.keyDown(with: event)
            return
        }
        input.handleKeyDown(event)
    }

    override func mouseMoved(with event: NSEvent) {
        input.handleMouseMoved(event, in: self)
    }

    override func mouseDown(with event: NSEvent) {
        input.handleMouseDown(event)
    }

    override var acceptsFirstResponder: Bool { true }
}
