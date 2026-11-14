import SwiftUI

@main
struct HerdrMenubarApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        // The app lives in the menu bar (see StatusItemController). SwiftUI needs a scene; this one is never shown.
        Settings {
            EmptyView()
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItemController: StatusItemController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard !Self.isTestHost else { return }
        statusItemController = StatusItemController()
    }

    /// True when the app was launched as the host for unit tests. Then it must not talk to the real herdr
    /// or ask for notification permission: the test run quits it seconds later, and macOS records the
    /// dismissed permission prompt as "not allowed".
    private static var isTestHost: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    }
}
