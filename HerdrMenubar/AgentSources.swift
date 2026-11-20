/// What each server the app follows reports. herdr and rex are followed independently, and either may not be
/// running: the user may use only one of them. See "Menu bar label" and "Dropdown" in `docs/PRD.md`.
struct AgentSources: Equatable {
    var herdr: AgentStore.State
    var rex: AgentStore.State

    func state(of source: AgentSource) -> AgentStore.State {
        switch source {
        case .herdr: herdr
        case .rex: rex
        }
    }

    /// Every server's agents, herdr's first, in the order the menu bar shows them.
    var agents: [Agent] {
        AgentSource.allCases.flatMap { source -> [Agent] in
            if case .loaded(let agents) = state(of: source) { return agents }
            return []
        }
    }

    /// One state for the menu bar: the agents of every server that could be read. Only when no server could be
    /// read, whether one is loading, one failed, or none is running, in that order.
    var combined: AgentStore.State {
        let states = AgentSource.allCases.map(state(of:))
        if states.contains(where: \.isLoaded) { return .loaded(agents) }
        if states.contains(.loading) { return .loading }
        for case .failed(let message) in states { return .failed(message) }
        return .notRunning
    }

    var isAnyRunning: Bool {
        AgentSource.allCases.contains { state(of: $0) != .notRunning }
    }

    /// The servers the dropdown shows a section for: those with agents, still loading, or that couldn't be read.
    /// A server that isn't running, or has no agents, is left out.
    var sections: [(source: AgentSource, state: AgentStore.State)] {
        AgentSource.allCases.compactMap { source in
            switch state(of: source) {
            case .notRunning: nil
            case .loaded(let agents) where agents.isEmpty: nil
            case let state: (source, state)
            }
        }
    }

    func agent(withPaneId paneId: String) -> Agent? {
        agents.first { $0.paneId == paneId }
    }
}

extension AgentStore.State {
    var isLoaded: Bool {
        if case .loaded = self { return true }
        return false
    }
}
