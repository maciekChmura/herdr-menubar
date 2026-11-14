/// A state change worth a notification: an agent became `blocked` or `done`.
/// See "Notifications" in `docs/PRD.md`.
struct AgentAlert: Equatable {
    enum Kind: Equatable {
        case blocked
        case done
    }

    let agent: Agent
    let kind: Kind

    var title: String {
        let folder = agent.folderName ?? agent.displayTitle
        switch kind {
        case .blocked: return "\(folder): needs input"
        case .done: return "\(folder): done"
        }
    }

    var body: String { agent.displayTitle }

    /// The alerts for the change from `previous` to `current`, matched by pane ID.
    ///
    /// - `previous` is nil for the first fetch after launch or after a reconnect. That fetch only sets the baseline,
    ///   so states that were already there don't notify.
    /// - A pane that wasn't in `previous` doesn't notify either: a newly detected agent hasn't *changed* state.
    static func alerts(previous: [Agent]?, current: [Agent]) -> [AgentAlert] {
        guard let previous else { return [] }
        let previousStatus = Dictionary(previous.map { ($0.paneId, $0.agentStatus) }, uniquingKeysWith: { first, _ in first })
        return current.compactMap { agent in
            guard let before = previousStatus[agent.paneId], before != agent.agentStatus else { return nil }
            switch agent.agentStatus {
            case .blocked: return AgentAlert(agent: agent, kind: .blocked)
            case .done: return AgentAlert(agent: agent, kind: .done)
            case .working, .idle, .unknown: return nil
            }
        }
    }

    /// Whether to show the notification. Skip it when the user is already looking at that agent:
    /// it's the focused pane in herdr and the terminal is the frontmost app.
    func shouldPost(terminalIsFrontmost: Bool) -> Bool {
        !(agent.focused && terminalIsFrontmost)
    }
}
