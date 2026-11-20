import Foundation

/// An agent's lifecycle state, as reported by herdr.
///
/// The cases are declared in display order. The menu bar label and the dropdown both use it.
enum AgentStatus: String, CaseIterable, Sendable {
    case blocked
    case working
    case done
    case idle
    case unknown
}

extension AgentStatus: Decodable {
    /// Unrecognized values decode as `.unknown`, so a newer herdr can't break decoding.
    init(from decoder: any Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = AgentStatus(rawValue: raw) ?? .unknown
    }
}

/// The server an agent comes from.
enum AgentSource: String, CaseIterable, Sendable {
    case herdr
    case rex

    /// The server's name, as the menu's section headers show it.
    var title: String { rawValue }
}

/// One agent from herdr's `agent.list`, or a rex terminal that reports a status (see `RexAgents`).
/// Only the fields this app uses are decoded.
///
/// For a rex agent, `paneId` is the terminal's block ID, `workspaceId` its session ID and `tabId` its window ID.
struct Agent: Decodable, Identifiable, Equatable, Sendable {
    let paneId: String
    let workspaceId: String
    let tabId: String
    /// The agent type, such as "claude".
    let agent: String?
    /// The name given with `herdr agent rename`, if any.
    let name: String?
    let agentStatus: AgentStatus
    /// Whether this is the focused pane in herdr.
    let focused: Bool
    let cwd: String?
    let foregroundCwd: String?
    let terminalTitleStripped: String?
    /// Commands the agent left running in the background. Not from herdr: `AgentStore` finds them in the
    /// process tree, and only for `done` and `idle` agents. See "Background jobs" in `docs/PRD.md`.
    var backgroundJobs: [BackgroundJob] = []
    /// Not from herdr's reply: rex agents set it.
    var source: AgentSource = .herdr
    /// What the agent says it's doing, such as "Running the test suite". Only rex reports one.
    var message: String?

    private enum CodingKeys: String, CodingKey {
        case paneId, workspaceId, tabId, agent, name, agentStatus, focused, cwd, foregroundCwd, terminalTitleStripped
    }

    var id: String { paneId }

    /// The terminal title, or the agent type when the title is empty.
    var displayTitle: String {
        if let title = terminalTitleStripped?.trimmingCharacters(in: .whitespaces), !title.isEmpty {
            return title
        }
        return agent ?? paneId
    }
}

/// The `result` of an `agent.list` request.
struct AgentListResult: Decodable, Sendable {
    let agents: [Agent]
}
