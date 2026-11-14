import AppKit
import Observation
import OSLog
import ServiceManagement

/// The "Launch at login" setting, backed by `SMAppService.mainApp`.
/// macOS keeps the setting itself, and the user can change it in System Settings → General → Login Items.
@MainActor
@Observable
final class LaunchAtLogin {
    private(set) var status: SMAppService.Status
    private let log = Logger(subsystem: "io.github.maciekchmura.HerdrMenubar", category: "login")

    init() {
        status = SMAppService.mainApp.status
        log.info("Launch at login: \(Self.name(of: self.status), privacy: .public)")
    }

    var isEnabled: Bool { status == .enabled }

    /// The toggle's title. When macOS wants the user to approve the login item, it says where.
    var title: String { Self.title(for: status) }

    nonisolated static func title(for status: SMAppService.Status) -> String {
        status == .requiresApproval ? "Launch at login (approve in System Settings)" : "Launch at login"
    }

    nonisolated static func name(of status: SMAppService.Status) -> String {
        switch status {
        case .enabled: "enabled"
        case .notRegistered: "off"
        case .requiresApproval: "waiting for approval in System Settings"
        case .notFound: "not found"
        @unknown default: "unknown (\(status.rawValue))"
        }
    }

    func set(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            log.error("Couldn't \(enabled ? "enable" : "disable", privacy: .public) launch at login: \(String(describing: error), privacy: .public)")
            NSSound.beep()
        }
        refresh()
        if status == .requiresApproval {
            SMAppService.openSystemSettingsLoginItems()
        }
    }

    /// Reads the status again, for example after the user changed it in System Settings.
    func refresh() {
        let current = SMAppService.mainApp.status
        guard current != status else { return }
        status = current
        log.info("Launch at login: \(Self.name(of: self.status), privacy: .public)")
    }
}
