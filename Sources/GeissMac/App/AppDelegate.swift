import AppKit

/// Owns one window per connected display, each with its own MetalRenderer.
/// Mirrors Geiss's original multi-monitor support (v4.27 in the Windows
/// changelog), but every screen renders instead of picking just one — except
/// in windowed debug mode, which only opens a single window.
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var windowControllers: [FullscreenWindowController] = []
    private var audioEngine: AudioCaptureEngine?
    private var trackWatcher: TrackWatcher?
    private var sharedInput: InputController?

    /// Set GEISS_WINDOWED=1 to run in a single normal window instead of taking
    /// over every display — use this while developing/validating, not for the
    /// real experience.
    private var isWindowedDebugMode: Bool {
        ProcessInfo.processInfo.environment["GEISS_WINDOWED"] != nil
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let input = InputController()
        sharedInput = input

        if isWindowedDebugMode {
            let screen = NSScreen.main ?? NSScreen.screens[0]
            windowControllers = [FullscreenWindowController(windowedOn: screen, input: input)]
        } else {
            windowControllers = NSScreen.screens.map { screen in
                FullscreenWindowController(fullscreenOn: screen, input: input)
            }
            NSApp.presentationOptions = [.hideDock, .hideMenuBar]
        }
        windowControllers.forEach { $0.showWindow() }
        NSApp.activate()

        // Needs an audio-capture permission — see AudioCaptureEngine's doc
        // comment for which one. Without it the visuals run without audio
        // (and the HUD says what to enable on the ScreenCaptureKit path).
        let engine = AudioCaptureEngine()
        audioEngine = engine
        engine.onAnalysis = { [weak input] analysis in
            input?.latestAudio = analysis
        }
        engine.onStartFailed = { [weak input] in
            input?.audioCaptureFailed()
        }
        // 'O' stops capture outright (as the original stopped DirectSound),
        // which also clears macOS's screen-recording indicator.
        input.onSoundToggled = { [weak engine] on in
            if on { engine?.start() } else { engine?.stop() }
        }
        engine.start()

        let watcher = TrackWatcher()
        trackWatcher = watcher
        watcher.onTrack = { [weak input] track in
            input?.trackChanged(track)
        }
        watcher.start()
    }

    // The original hid the cursor every frame (`SetCursor(NULL)`,
    // main.cpp:5433); the mouse still steers the zoom center. Hidden while
    // active (a hide made before activation can silently not take), shown
    // again when switching away; the fullscreen views also carry a blank
    // cursor (GeissMTKView.resetCursorRects).
    func applicationDidBecomeActive(_ notification: Notification) {
        if !isWindowedDebugMode { NSCursor.hide() }
    }

    func applicationDidResignActive(_ notification: Notification) {
        if !isWindowedDebugMode { NSCursor.unhide() }
    }

    func applicationWillTerminate(_ notification: Notification) {
        trackWatcher?.stop()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}
