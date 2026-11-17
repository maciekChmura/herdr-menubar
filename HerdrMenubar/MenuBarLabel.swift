/// How the menu bar item summarizes the agents. The user picks it in the menu.
enum MenuBarStyle: String, CaseIterable {
    /// A dot and a count per state. See `StatusDotsView`.
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
    /// A dot and a count for each state that has agents, in display order, and how many agents have
    /// background jobs. See `backgroundIndex(in:)` for where that count goes.
    case counts([StatusCount], inBackground: Int)
    /// One dot per agent, in herdr's order, drawn by `DotsImage`.
    case dots([PaneStatus])
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
            case .counts:
                self = .counts(Self.statusCounts(of: agents), inBackground: agents.count { !$0.backgroundJobs.isEmpty })
            case .dots:
                self = .dots(agents.map {
                    PaneStatus(paneId: $0.paneId, status: $0.agentStatus, hasBackgroundJobs: !$0.backgroundJobs.isEmpty)
                })
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

    /// Where the count of agents with background jobs goes among the state counts: after blocked and working,
    /// since something is still running.
    static func backgroundIndex(in counts: [StatusCount]) -> Int {
        counts.firstIndex { $0.status != .blocked && $0.status != .working } ?? counts.count
    }

    /// The counts as emoji, such as "🔴1 🟢2 🔵3 ⚪1", for the log. Agents with background jobs are added as "⏳1".
    static func counts(of agents: [Agent]) -> String {
        var parts = AgentStatus.allCases.compactMap { status in
            let count = agents.count { $0.agentStatus == status }
            return count > 0 ? "\(status.glyph)\(count)" : nil
        }
        let inBackground = agents.count { !$0.backgroundJobs.isEmpty }
        if inBackground > 0 { parts.append("⏳\(inBackground)") }
        return parts.joined(separator: " ")
    }

    /// The counts in words, such as "1 blocked, 2 working, 1 with background jobs", for VoiceOver.
    static func spokenSummary(of counts: [StatusCount], inBackground: Int = 0) -> String {
        var parts = counts.map { "\($0.count) \($0.status.rawValue)" }
        if inBackground > 0 {
            parts.insert("\(inBackground) with background jobs", at: backgroundIndex(in: counts))
        }
        return parts.joined(separator: ", ")
    }
}

/// One agent's dot in dots mode. The pane ID lets a state change fade and pop on the right dot.
struct PaneStatus: Equatable, Sendable {
    let paneId: String
    let status: AgentStatus
    /// Shown as a green ring around the dot. See "Background jobs" in `docs/PRD.md`.
    var hasBackgroundJobs = false
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
