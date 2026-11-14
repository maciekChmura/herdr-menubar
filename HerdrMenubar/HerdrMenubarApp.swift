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
            AgentMenu(state: store.state)
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

/// The agent part of the dropdown. M3 turns these into full rows.
struct AgentMenu: View {
    let state: AgentStore.State

    var body: some View {
        switch state {
        case .loading:
            Text("Loading…")
        case .notRunning:
            Text("herdr server is not running")
            Text("Start it by running herdr")
        case .failed(let message):
            Text("Couldn't read agents from herdr")
            Text(message)
        case .loaded(let agents) where agents.isEmpty:
            Text("No agents")
        case .loaded(let agents):
            ForEach(agents) { agent in
                Text(agent.displayTitle)
            }
        }
    }
}
