import Foundation

/// Which rex terminals are agents, and their state. See "Which terminals are agents" in `docs/PRD.md`.
enum RexAgents {
    static let terminalCreator = "com.superlogical.terminal"

    /// What a fetch learned about one terminal.
    struct Terminal: Equatable, Sendable {
        var sessionId: String
        var blockId: String
        var windowId: String?
        var records: [RexStatusRecord]
        /// The terminal's foreground process, or nil when it has none.
        var foreground: RexProcess?
        /// False when rex couldn't say what the foreground process is. Then no record is left out for its owner.
        var foregroundKnown = true
        var title: String?
    }

    /// Messages longer than this are cut short with "…".
    static let maxMessageLength = 80

    /// The terminal as an agent, or nil when no record that still counts is left.
    static func agent(for terminal: Terminal) -> Agent? {
        let records = terminal.foregroundKnown
            ? liveRecords(terminal.records, foreground: terminal.foreground)
            : terminal.records
        guard let (status, record) = mostUrgent(records) else { return nil }
        return Agent(
            paneId: terminal.blockId,
            workspaceId: terminal.sessionId,
            tabId: terminal.windowId ?? "",
            agent: record.effectiveApp ?? records.lazy.compactMap(\.effectiveApp).first,
            name: nil,
            agentStatus: status,
            // Rex can't say which session Rex.app shows. See "Limits" in docs/PRD.md.
            focused: false,
            cwd: nil,
            foregroundCwd: terminal.foreground?.cwd,
            terminalTitleStripped: terminal.title?.trimmingCharacters(in: .whitespaces),
            source: .rex,
            message: record.msg.flatMap(shortened)
        )
    }

    /// The records that still describe something running. An `idle`, `working` or `blocked` record whose owner
    /// isn't the terminal's foreground process any more outlived its program: rex keeps `idle` records after the
    /// program exits. `done` and `error` records are meant to outlive their program, so they always count.
    static func liveRecords(_ records: [RexStatusRecord], foreground: RexProcess?) -> [RexStatusRecord] {
        records.filter { record in
            if record.state == "done" || record.state == "error" { return true }
            guard let owner = record.owner else { return true }
            guard let foreground else { return false }
            return owner.pid == foreground.pid && owner.name == foreground.name
        }
    }

    /// The most urgent state among `records`, and the first record in that state. Rex lists the root record first.
    static func mostUrgent(_ records: [RexStatusRecord]) -> (AgentStatus, RexStatusRecord)? {
        let statuses = records.map { (status(of: $0.state), $0) }
        for status in AgentStatus.allCases {
            if let match = statuses.first(where: { $0.0 == status }) { return match }
        }
        return nil
    }

    /// The app's state for a rex state. `error` (failed and stopped) shows as `done`: the work is over and the
    /// user hasn't seen it yet. Rex's docs say to treat a state they don't know as `idle`.
    static func status(of state: String) -> AgentStatus {
        switch state {
        case "blocked": .blocked
        case "working": .working
        case "done", "error": .done
        default: .idle
        }
    }

    private static func shortened(_ message: String) -> String? {
        let trimmed = message.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        guard trimmed.count > maxMessageLength else { return trimmed }
        return trimmed.prefix(maxMessageLength - 1).trimmingCharacters(in: .whitespaces) + "…"
    }
}
