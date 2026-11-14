import SwiftUI

@main
struct HerdrMenubarApp: App {
    @State private var store: AgentStore
    @State private var notifier: Notifier

    init() {
        let store = AgentStore(client: HerdrClient(socketPath: HerdrClient.resolveSocketPath()))
        let notifier = Notifier()
        _store = State(initialValue: store)
        _notifier = State(initialValue: notifier)
        guard !Self.isTestHost else { return }

        store.onAlerts = { alerts in
            let terminalIsFrontmost = TerminalApp.isFrontmost
            for alert in alerts where alert.shouldPost(terminalIsFrontmost: terminalIsFrontmost) {
                notifier.post(alert)
            }
        }
        // Clicking a notification does the same as clicking the agent's row.
        notifier.onOpen = { paneId in
            Task { await Self.focus(paneId: paneId, store: store) }
        }
        notifier.requestAuthorization()
        store.start()
    }

    var body: some Scene {
        MenuBarExtra {
            AgentMenu(state: store.state, onSelect: { agent in
                Task { await Self.focus(paneId: agent.paneId, store: store) }
            })
            Divider()
            Button("Quit") {
                NSApplication.shared.terminate(nil)
            }
            .keyboardShortcut("q")
        } label: {
            MenuBarLabelView(label: MenuBarLabel(store.state))
        }
        .menuBarExtraStyle(.menu)
    }

    /// True when the app was launched as the host for unit tests. Then it must not talk to the real herdr
    /// or ask for notification permission: the test run quits it seconds later, and macOS records the
    /// dismissed permission prompt as "not allowed".
    private static var isTestHost: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    }

    /// Focuses the agent in herdr and brings the terminal to the front, or beeps if herdr refused.
    @MainActor
    private static func focus(paneId: String, store: AgentStore) async {
        if await store.focus(paneId: paneId) {
            TerminalApp.activate()
        } else {
            NSSound.beep()
        }
    }
}

struct MenuBarLabelView: View {
    let label: MenuBarLabel

    var body: some View {
        switch label {
        case .counts(let text):
            Text(text)
        case .symbol(let name):
            Image(systemName: name)
        }
    }
}

/// The agent part of the dropdown: a header and one row per agent, or a status message.
struct AgentMenu: View {
    let state: AgentStore.State
    let onSelect: (Agent) -> Void

    var body: some View {
        switch state {
        case .loading:
            Text("Loading…")
        case .notRunning:
            Text("herdr server is not running")
            Text("Start it by running \"herdr\" in a terminal")
        case .failed(let message):
            Text("Couldn't read agents from herdr")
            Text(message)
        case .loaded(let agents):
            Text(AgentRow.header(agentCount: agents.count))
            if !agents.isEmpty {
                Divider()
                ForEach(AgentRow.rows(for: agents)) { row in
                    // A toggle shows the native menu checkmark on the focused agent.
                    Toggle(row.text, isOn: Binding(
                        get: { row.agent.focused },
                        set: { _ in onSelect(row.agent) }
                    ))
                }
            }
        }
    }
}
