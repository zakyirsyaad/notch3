import AppKit
import NotchAgentCore

// NotchAgent — native macOS menu-bar / notch companion app.
// Runs the NotchHUD shell, spawns the Node.js agent runtime subprocess,
// and manages the dual-wallet security lifecycle.

@main
enum NotchAgentApp {
    /// NSApplication does not retain its delegate — keep a strong reference.
    @MainActor static var retainedDelegate: AppDelegate?

    static func main() {
        MainActor.assumeIsolated {
            let app = NSApplication.shared
            let delegate = AppDelegate()
            Self.retainedDelegate = delegate
            app.delegate = delegate
            app.setActivationPolicy(.accessory)  // menu-bar agent: no Dock icon
            _ = app.run()
        }
    }
}
