import AppKit
import MetalKit

/// Borderless window covering one NSScreen, hosting a GeissMTKView.
/// This is where Geiss's original WM_KEYDOWN / WM_MOUSEMOVE handling (main.cpp
/// around SaverWindowProc / WindowProc) gets reborn as normal NSResponder events —
/// no OS-level "any input dismisses the view" fight, because this is just an app window.
final class FullscreenWindowController: NSWindowController {
    private init(window: NSWindow) {
        super.init(window: window)
    }

    required init?(coder: NSCoder) { fatalError("unused") }

    /// Real mode: one borderless window per screen, above the menu bar. Used
    /// whenever GEISS_WINDOWED is not set in the environment.
    convenience init(fullscreenOn screen: NSScreen, input: InputController) {
        let window = FullscreenWindow(
            contentRect: screen.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false,
            screen: screen
        )
        // Normal level: the app hides the Dock and menu bar instead
        // (AppDelegate's presentationOptions), so system UI such as Force
        // Quit and permission alerts can still appear above it.
        window.level = .normal
        window.isOpaque = true
        window.hasShadow = false
        window.ignoresMouseEvents = false
        window.acceptsMouseMovedEvents = true
        let view = GeissMTKView(frame: screen.frame, input: input, titlePrefix: AppInfo.name)
        view.hidesCursor = true
        window.contentView = view

        self.init(window: window)
    }

    /// Debug mode: a single normal, closable, resizable window that does not
    /// cover the whole screen or hide the Dock/menu bar. Enabled by running
    /// with `GEISS_WINDOWED=1` — for validating the render/audio pipeline
    /// without taking over the display while developing.
    convenience init(windowedOn screen: NSScreen, input: InputController) {
        let rect = NSRect(x: 0, y: 0, width: 1280, height: 720)
        let window = NSWindow(
            contentRect: rect,
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false,
            screen: screen
        )
        window.title = "\(AppInfo.name) (windowed debug)"
        window.center()
        window.acceptsMouseMovedEvents = true
        window.contentView = GeissMTKView(frame: rect, input: input, titlePrefix: "\(AppInfo.name) (windowed debug)")

        self.init(window: window)
    }

    func showWindow() {
        window?.makeKeyAndOrderFront(nil)
        window?.makeFirstResponder(window?.contentView)
    }
}

/// Borderless windows can't become key by default, which left the
/// fullscreen view deaf to every key — Escape included.
private final class FullscreenWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}
