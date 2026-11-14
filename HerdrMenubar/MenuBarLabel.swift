/// How the menu bar item summarizes the agents. The user picks it in the menu.
enum MenuBarStyle: String, CaseIterable {
    /// A dot and a count per state. See `DotsImage.countsImage(for:)`.
    case counts
    /// One small colored dot per agent, in herdr's order. See `DotsImage`.
    case dots

    var title: String {
        switch self {
        case .counts: "Counts per state"
        case .dots: "One dot per agent"
        }
    }
}

/// What the menu bar item shows. See "Menu bar label" in `docs/PRD.md`.
enum MenuBarLabel: Equatable {
    /// A dot and a count for each state that has agents, in display order.
    case counts([StatusCount])
    /// One dot per agent, in herdr's order, drawn by `DotsImage`.
    case dots([AgentStatus])
    /// An SF Symbol name.
    case symbol(String)

    static let noAgentsSymbol = "circle.dashed"
    static let unreachableSymbol = "exclamationmark.circle"

    init(_ state: AgentStore.State, style: MenuBarStyle) {
        switch state {
        case .loading:
            self = .symbol(Self.noAgentsSymbol)
        case .notRunning, .failed:
            self = .symbol(Self.unreachableSymbol)
        case .loaded(let agents) where agents.isEmpty:
            self = .symbol(Self.noAgentsSymbol)
        case .loaded(let agents):
            switch style {
            case .counts: self = .counts(Self.statusCounts(of: agents))
            case .dots: self = .dots(agents.map(\.agentStatus))
            }
        }
    }

    /// The number of agents in each state, in display order, leaving out states with no agents.
    static func statusCounts(of agents: [Agent]) -> [StatusCount] {
        statusCounts(of: agents.map(\.agentStatus))
    }

    static func statusCounts(of statuses: [AgentStatus]) -> [StatusCount] {
        AgentStatus.allCases.compactMap { status in
            let count = statuses.count { $0 == status }
            return count > 0 ? StatusCount(status: status, count: count) : nil
        }
    }

    /// The counts as emoji, such as "🔴1 🟢2 🔵3 ⚪1", for the log.
    static func counts(of agents: [Agent]) -> String {
        AgentStatus.allCases
            .compactMap { status in
                let count = agents.count { $0.agentStatus == status }
                return count > 0 ? "\(status.glyph)\(count)" : nil
            }
            .joined(separator: " ")
    }

    /// The counts in words, such as "1 blocked, 2 working", for VoiceOver.
    static func spokenSummary(of counts: [StatusCount]) -> String {
        counts.map { "\($0.count) \($0.status.rawValue)" }.joined(separator: ", ")
    }
}

struct StatusCount: Equatable, Sendable {
    let status: AgentStatus
    let count: Int
}

extension AgentStatus {
    var glyph: String {
        switch self {
        case .blocked: "🔴"
        case .working: "🟢"
        case .done: "🔵"
        case .idle: "⚪"
        case .unknown: "⚫"
        }
    }
}
