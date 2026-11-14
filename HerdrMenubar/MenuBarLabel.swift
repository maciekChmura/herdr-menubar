/// How the menu bar item summarizes the agents. The user picks it in the menu.
enum MenuBarStyle: String, CaseIterable {
    /// One count per state, such as "🔴1 🟢2 🔵3 ⚪1".
    case counts
    /// One dot per agent, in herdr's order, such as "🟢🔴🟢".
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
    /// Counts or dots, made of state glyphs.
    case text(String)
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
            case .counts: self = .text(Self.counts(of: agents))
            case .dots: self = .text(Self.dots(of: agents))
            }
        }
    }

    /// One glyph and count per state, in display order, leaving out states with no agents.
    static func counts(of agents: [Agent]) -> String {
        AgentStatus.allCases
            .compactMap { status in
                let count = agents.count { $0.agentStatus == status }
                return count > 0 ? "\(status.glyph)\(count)" : nil
            }
            .joined(separator: " ")
    }

    /// One glyph per agent, in the order herdr lists them, so each agent keeps its place
    /// and only its color changes.
    static func dots(of agents: [Agent]) -> String {
        agents.map(\.agentStatus.glyph).joined()
    }
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
