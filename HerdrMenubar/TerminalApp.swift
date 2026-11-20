import AppKit

/// The app that shows an agent's terminal.
struct TerminalApp: Sendable {
    let bundleIdentifier: String

    /// Runs the herdr TUI. v1 assumes Ghostty.
    static let ghostty = TerminalApp(bundleIdentifier: "com.mitchellh.ghostty")
    static let rex = TerminalApp(bundleIdentifier: "com.superlogical.rex")

    /// The app that shows the agents of `source`.
    static func showing(_ source: AgentSource) -> TerminalApp {
        switch source {
        case .herdr: .ghostty
        case .rex: .rex
        }
    }

    /// Brings the app to the front. Does nothing if it isn't running, so it never opens a new window.
    @MainActor
    func activate() {
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier).first,
              let url = app.bundleURL
        else { return }
        // Opening a running app activates it. This is more reliable than NSRunningApplication.activate(),
        // which macOS 14 can refuse when the calling app isn't active itself.
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.openApplication(at: url, configuration: configuration)
    }

    /// Whether the app is the frontmost app.
    @MainActor
    var isFrontmost: Bool {
        NSWorkspace.shared.frontmostApplication?.bundleIdentifier == bundleIdentifier
    }
}
