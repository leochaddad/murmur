import AppKit

@main
enum MurmurApp {
    @MainActor
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        withExtendedLifetime(delegate) {
            app.run()
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var controller: AppController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Unit tests use the app as their host; don't start the menu bar app for them.
        guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil else { return }
        let controller = AppController()
        controller.start()
        self.controller = controller
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        // Launching Murmur again (Finder, Spotlight) opens Settings.
        controller?.showSettings(nil)
        return false
    }

    func applicationWillTerminate(_ notification: Notification) {
        controller?.shutdown()
    }
}
