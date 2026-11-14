import SwiftUI

@main
struct HerdrMenubarApp: App {
    @State private var store: AgentStore

    init() {
        let store = AgentStore(client: HerdrClient(socketPath: HerdrClient.resolveSocketPath()))
        _store = State(initialValue: store)
        // M1 loads the agents once at launch. M2 keeps them live.
        Task { await store.refresh() }
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
            // Placeholder until M2 draws the per-state counts.
            Image(systemName: "circle.dashed")
        }
        .menuBarExtraStyle(.menu)
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
