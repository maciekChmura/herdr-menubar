import Foundation

/// One agent's row in the dropdown. See "Dropdown" in `docs/PRD.md`.
struct AgentRow: Identifiable, Equatable {
    let agent: Agent

    var id: String { agent.paneId }

    /// The title and the folder, such as "Fix login tests — project-a". The state is shown as a dot next to it.
    var title: String {
        guard let folder = agent.folderName else { return agent.displayTitle }
        return "\(agent.displayTitle) — \(folder)"
    }

    /// The lines under the row: what a rex agent says it's doing, then its background jobs.
    /// Nil when there's neither. See "Dropdown" in `docs/PRD.md`.
    func subtitle(now: Date) -> String? {
        let lines = [agent.message, backgroundSummary(now: now)].compactMap { $0 }
        return lines.isEmpty ? nil : lines.joined(separator: "\n")
    }

    /// The agent's background jobs, such as "In background: npm test (12m)", or nil when it has none.
    /// Shown on a second line under the row. See "Background jobs" in `docs/PRD.md`.
    func backgroundSummary(now: Date) -> String? {
        guard !agent.backgroundJobs.isEmpty else { return nil }
        let jobs = agent.backgroundJobs.map { "\($0.command) (\(BackgroundJobs.duration(from: $0.startDate, to: now)))" }
        return "In background: " + jobs.joined(separator: ", ")
    }

    /// Rows in the order that matches the menu bar: in dots mode, herdr's order, so the 2nd dot is the 2nd row;
    /// in counts mode, sorted by state, like the counts.
    static func rows(for agents: [Agent], matching style: MenuBarStyle) -> [AgentRow] {
        switch style {
        case .dots: agents.map(AgentRow.init)
        case .counts: rows(for: agents)
        }
    }

    /// Rows sorted by state in display order, then by folder name.
    static func rows(for agents: [Agent]) -> [AgentRow] {
        agents
            .sorted { a, b in
                let stateA = AgentStatus.allCases.firstIndex(of: a.agentStatus)!
                let stateB = AgentStatus.allCases.firstIndex(of: b.agentStatus)!
                if stateA != stateB { return stateA < stateB }
                let byFolder = (a.folderName ?? "").localizedStandardCompare(b.folderName ?? "")
                if byFolder != .orderedSame { return byFolder == .orderedAscending }
                // Keep the order stable when state and folder are the same.
                return a.paneId < b.paneId
            }
            .map(AgentRow.init)
    }

    /// The dropdown's header line.
    static func header(agentCount: Int) -> String {
        switch agentCount {
        case 0: "No agents"
        case 1: "1 agent"
        default: "\(agentCount) agents"
        }
    }
}

extension Agent {
    /// The last path component of the foreground working directory, falling back to `cwd`.
    var folderName: String? {
        guard let path = foregroundCwd ?? cwd, !path.isEmpty else { return nil }
        return URL(fileURLWithPath: path).lastPathComponent
    }
}
