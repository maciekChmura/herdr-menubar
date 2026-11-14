import AppKit

/// The terminal app that runs the herdr TUI. v1 assumes Ghostty.
enum TerminalApp {
    static let bundleIdentifier = "com.mitchellh.ghostty"

    /// Brings the terminal to the front. Does nothing if it isn't running, so it never opens a new terminal.
    @MainActor
    static func activate() {
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier).first,
              let url = app.bundleURL
        else { return }
        // Opening a running app activates it. This is more reliable than NSRunningApplication.activate(),
        // which macOS 14 can refuse when the calling app isn't active itself.
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.openApplication(at: url, configuration: configuration)
    }

    /// Whether the terminal is the frontmost app.
    @MainActor
    static var isFrontmost: Bool {
        NSWorkspace.shared.frontmostApplication?.bundleIdentifier == bundleIdentifier
    }
}
