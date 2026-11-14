import SwiftUI

@main
struct HerdrMenubarApp: App {
    @State private var store: AgentStore

    init() {
        let store = AgentStore(client: HerdrClient(socketPath: HerdrClient.resolveSocketPath()))
        _store = State(initialValue: store)
        store.start()
    }

    var body: some Scene {
        MenuBarExtra {
            AgentMenu(state: store.state, onSelect: { agent in
                Task {
                    if await store.focus(agent) {
                        TerminalApp.activate()
                    } else {
                        NSSound.beep()
                    }
                }
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
