import AppKit

/// The name people see: menu, window titles, messages. The code and the
/// Application Support folder keep "GeissMac", so saved presets and
/// ratings carry over.
enum AppInfo {
    static let name = "Geiss It Werks on a Mac"
}

// Entry point. Plain AppKit (not SwiftUI's App/Scene) because we need full control
// over borderless fullscreen NSWindows across every connected NSScreen, and direct
// access to key/mouse events for effect control (see Input/InputController.swift).
@main
struct GeissMacApp {
    static func main() {
        // Without this, stdout is fully-buffered (not line-buffered) whenever
        // it's piped rather than attached to a real tty — e.g. `swift run
        // GeissMac > log.txt` — so print() calls from background queues (audio
        // capture, etc.) can sit invisible in the buffer for a long time.
        setvbuf(stdout, nil, _IOLBF, 0)

        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.regular)
        app.mainMenu = makeMainMenu()
        app.run()
    }

    /// Just the app menu with Quit, so ⌘Q works — its key equivalent fires
    /// even while the menu bar is hidden in fullscreen.
    private static func makeMainMenu() -> NSMenu {
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Quit \(AppInfo.name)", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        let appItem = NSMenuItem()
        appItem.submenu = appMenu
        let mainMenu = NSMenu()
        mainMenu.addItem(appItem)
        return mainMenu
    }
}
