/// What the menu bar item shows. See "Menu bar label" in `docs/PRD.md`.
enum MenuBarLabel: Equatable {
    /// Per-state counts, such as "🔴1 🟢2 ✅3 ⚪1".
    case counts(String)
    /// An SF Symbol name.
    case symbol(String)

    static let noAgentsSymbol = "circle.dashed"
    static let unreachableSymbol = "exclamationmark.circle"

    init(_ state: AgentStore.State) {
        switch state {
        case .loading:
            self = .symbol(Self.noAgentsSymbol)
        case .notRunning, .failed:
            self = .symbol(Self.unreachableSymbol)
        case .loaded(let agents) where agents.isEmpty:
            self = .symbol(Self.noAgentsSymbol)
        case .loaded(let agents):
            self = .counts(Self.counts(of: agents))
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
}

extension AgentStatus {
    var glyph: String {
        switch self {
        case .blocked: "🔴"
        case .working: "🟢"
        case .done: "✅"
        case .idle: "⚪"
        case .unknown: "❔"
        }
    }
}
