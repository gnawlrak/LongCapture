import AppKit

@main
struct LongCaptureApp {
    @MainActor
    static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let delegate = AppDelegate()
        app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var controller: AppController?
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Hosted unit tests must not register a second hotkey or create menu-bar UI.
        guard NSClassFromString("XCTestCase") == nil else { return }
        controller = AppController()
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let controller else { return .terminateNow }
        Task { sender.reply(toApplicationShouldTerminate: await controller.requestTermination()) }
        return .terminateLater
    }
}
