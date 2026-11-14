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

/// One agent from herdr's `agent.list`. Only the fields this app uses are decoded.
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
