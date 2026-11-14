import Foundation
import OSLog
import UserNotifications

/// Posts macOS notifications for agent alerts and reports when the user clicks one.
@MainActor
final class Notifier: NSObject {
    /// Called with the pane ID of the agent whose notification was clicked.
    var onOpen: ((String) -> Void)?

    private let center = UNUserNotificationCenter.current()
    private let log = Logger(subsystem: "io.github.maciekchmura.HerdrMenubar", category: "notifications")
    private nonisolated static let paneIdKey = "paneId"

    override init() {
        super.init()
        center.delegate = self
    }

    /// Asks for permission. macOS shows the prompt only the first time.
    func requestAuthorization() {
        Task {
            do {
                let granted = try await center.requestAuthorization(options: [.alert, .sound])
                log.info("Notification permission granted: \(granted)")
            } catch {
                log.error("Couldn't request notification permission: \(String(describing: error), privacy: .public)")
            }
        }
    }

    func post(_ alert: AgentAlert) {
        let content = UNMutableNotificationContent()
        content.title = alert.title
        content.body = alert.body
        content.sound = .default
        content.threadIdentifier = alert.agent.paneId
        content.userInfo = [Self.paneIdKey: alert.agent.paneId]

        // One identifier per pane: a newer notification for the same agent replaces the older one.
        let request = UNNotificationRequest(identifier: "agent-\(alert.agent.paneId)", content: content, trigger: nil)
        let paneId = alert.agent.paneId
        let log = log
        center.add(request) { error in
            if let error {
                log.error("Couldn't post the notification for pane \(paneId, privacy: .public): \(String(describing: error), privacy: .public)")
            }
        }
        log.info("Posted a notification for pane \(paneId, privacy: .public)")
    }
}

extension Notifier: UNUserNotificationCenterDelegate {
    /// Show notifications even if this app happens to be active.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        guard response.actionIdentifier == UNNotificationDefaultActionIdentifier,
              let paneId = response.notification.request.content.userInfo[Self.paneIdKey] as? String
        else { return }
        await MainActor.run { onOpen?(paneId) }
    }
}
