import Foundation
import Observation
import OSLog

/// What the app currently knows about the agents in rex's terminals, kept in sync with the server.
///
/// See "Keeping rex state in sync" in `docs/PRD.md`. A fetch reads every terminal's status; events only say
/// when to fetch again.
@MainActor
@Observable
final class RexStore {
    /// The events after which the agents are fetched again. Every other event is ignored, in particular the
    /// client events that every `rex` command causes.
    nonisolated static let refreshEvents: Set<String> = [
        "program_status_changed", "program_status_removed", "process_changed", "title_changed", "child_exited",
        "block_closed", "session_created", "session_destroyed", "session_moved",
    ]

    private(set) var state: AgentStore.State = .loading
    private let client: RexClient
    private let timing: AgentStore.Timing
    private let processes: ProcessSource
    @ObservationIgnored private var syncTask: Task<Void, Never>?
    @ObservationIgnored private var connection: RexConnection?
    @ObservationIgnored private var connected = false
    /// True until the first fetch after launch or after a lost connection: that fetch only sets the baseline
    /// for alerts, so states that were already there, or changed while disconnected, don't notify.
    @ObservationIgnored private var needsBaseline = true
    /// Called with the alerts from each fetch that has any. See `AgentAlert`.
    @ObservationIgnored var onAlerts: (([AgentAlert]) -> Void)?
    /// Called with the agents whenever they change, and with none when rex can't be read.
    @ObservationIgnored var onAgentsChanged: (([Agent]) -> Void)?
    private let log = Logger(subsystem: "io.github.maciekchmura.HerdrMenubar", category: "rex")

    init(client: RexClient, timing: AgentStore.Timing = AgentStore.Timing(), processes: ProcessSource = .system) {
        self.client = client
        self.timing = timing
        self.processes = processes
    }

    /// Starts keeping `state` in sync. Calling it again while running does nothing.
    func start() {
        guard syncTask == nil else { return }
        syncTask = Task { await self.syncUntilCancelled() }
    }

    func stop() {
        syncTask?.cancel()
        syncTask = nil
    }

    /// Focuses the agent's terminal and asks Rex.app to show its session. Returns false and logs the error if
    /// the terminal couldn't be focused. See "Clicking an agent" in `docs/PRD.md`.
    func focus(paneId: String) async -> Bool {
        guard let connection, case .loaded(let agents) = state, let agent = agents.first(where: { $0.paneId == paneId }) else {
            log.error("Couldn't focus the rex terminal \(paneId, privacy: .public): not connected to rex")
            return false
        }
        do {
            try await connection.focusBlock(session: agent.workspaceId, block: agent.paneId)
            log.info("Focused the rex terminal \(paneId, privacy: .public)")
        } catch {
            log.error("Couldn't focus the rex terminal \(paneId, privacy: .public): \(String(describing: error), privacy: .public)")
            return false
        }
        do {
            for app in try await connection.appClients() where app.isLocalMacApp {
                try await connection.selectSession(agent.workspaceId, inClient: app.clientId)
            }
        } catch HerdrError.server(code: "refused", message: _) {
            log.info("Rex.app didn't switch to the agent's session. Turn on Remote Control in Rex's settings to let it.")
        } catch {
            log.error("Couldn't ask Rex.app to show the session: \(String(describing: error), privacy: .public)")
        }
        return true
    }

    private func syncUntilCancelled() async {
        var retryDelay = timing.initialRetryDelay
        while !Task.isCancelled {
            connected = false
            do {
                try await runSession()
            } catch is CancellationError {
                return
            } catch HerdrError.notRunning {
                needsBaseline = true
                if state != .notRunning {
                    log.info("rex server is not running at \(self.client.socketPath, privacy: .public)")
                }
                setState(.notRunning)
            } catch {
                guard !Task.isCancelled else { return }
                log.error("Lost the rex connection: \(String(describing: error), privacy: .public)")
                needsBaseline = true
                // Keep showing the last agents we had; the next attempt corrects them.
                if case .loaded = state {} else { setState(.failed(String(describing: error))) }
            }

            if connected { retryDelay = timing.initialRetryDelay }
            try? await Task.sleep(for: retryDelay)
            retryDelay = min(retryDelay * 2, timing.maxRetryDelay)
        }
    }

    /// Connects, starts events, and fetches on every event that matters until the connection drops (throws).
    private func runSession() async throws {
        let connection = try await client.connect()
        self.connection = connection
        defer {
            connection.close()
            self.connection = nil
        }
        // Events start before the first fetch, so no change can fall between the two.
        try await connection.attachAll()
        connected = true
        log.info("Connected to rex")

        let processes = processes
        let first = try await Self.fetch(connection, processes: processes)
        apply(first.agents, isBaseline: needsBaseline)
        needsBaseline = false

        let (triggers, trigger) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let (rechecks, recheck) = AsyncStream<Date>.makeStream(bufferingPolicy: .bufferingNewest(1))
        if let date = first.recheckDate { recheck.yield(date) }

        let timing = timing
        let log = log
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                for try await event in connection.events where Self.refreshEvents.contains(event.name) {
                    log.debug("Event \(event.name, privacy: .public)")
                    trigger.yield()
                }
                throw HerdrError.connectionClosed
            }
            group.addTask {
                while true {
                    try await Task.sleep(for: timing.safetyRefreshInterval)
                    trigger.yield()
                }
            }
            group.addTask {
                // A process was too young to count as a background job: look again once it's old enough.
                for await date in rechecks {
                    try await Task.sleep(for: .seconds(max(date.timeIntervalSinceNow, 0) + 0.1))
                    trigger.yield()
                }
            }
            group.addTask { [weak self] in
                // Triggers that arrive while waiting or fetching collapse into one buffered trigger.
                for await _ in triggers {
                    try await Task.sleep(for: timing.refreshDebounce)
                    let fetch = try await Self.fetch(connection, processes: processes)
                    guard let self else { return }
                    await self.apply(fetch.agents)
                    if let date = fetch.recheckDate { recheck.yield(date) }
                }
            }
            try await group.next()
            group.cancelAll()
        }
    }

    /// Reads every terminal's status, and the background jobs of the agents waiting for input.
    /// A session or block that disappears during the fetch is left out; a lost connection throws.
    nonisolated static func fetch(_ connection: RexConnection, processes: ProcessSource) async throws -> AgentStore.Fetch {
        let sessions = try await connection.sessions()
        let blockLists = try await withThrowingTaskGroup(of: (Int, [RexBlock]).self) { tasks in
            for (index, session) in sessions.enumerated() {
                tasks.addTask { (index, try await Self.unlessRefused { try await connection.blocks(inSession: session.sessionId) } ?? []) }
            }
            var lists = [[RexBlock]](repeating: [], count: sessions.count)
            for try await (index, blocks) in tasks { lists[index] = blocks }
            return lists
        }

        var candidates: [RexAgents.Terminal] = []
        for (session, blocks) in zip(sessions, blockLists) {
            for block in blocks where block.creatorName == RexAgents.terminalCreator {
                guard let blockId = block.blockId else { continue }
                candidates.append(RexAgents.Terminal(sessionId: session.sessionId, blockId: blockId, windowId: block.windowId, records: []))
            }
        }

        let terminals = try await withThrowingTaskGroup(of: (Int, RexAgents.Terminal?).self) { tasks in
            for (index, candidate) in candidates.enumerated() {
                tasks.addTask { (index, try await Self.read(candidate, from: connection)) }
            }
            var terminals = [RexAgents.Terminal?](repeating: nil, count: candidates.count)
            for try await (index, terminal) in tasks { terminals[index] = terminal }
            return terminals.compactMap { $0 }
        }

        var agents: [Agent] = []
        var foregroundPids: [Int: Int32] = [:]
        for terminal in terminals {
            guard let agent = RexAgents.agent(for: terminal) else { continue }
            if [.done, .idle].contains(agent.agentStatus), let pid = terminal.foreground?.pid {
                foregroundPids[agents.count] = pid
            }
            agents.append(agent)
        }
        guard !foregroundPids.isEmpty else { return AgentStore.Fetch(agents: agents) }

        // While an agent waits for input, the terminal's foreground process is the agent, and its group is the
        // agent's group. See "Background jobs" in docs/PRD.md.
        let table = processes.list()
        let groups = Dictionary(table.map { ($0.pid, $0.groupId) }, uniquingKeysWith: { first, _ in first })
        let now = Date()
        var recheckDate: Date?
        for (index, pid) in foregroundPids {
            guard let group = groups[pid] else { continue }
            let scan = BackgroundJobs.scan(agentGroup: group, in: table, now: now, arguments: processes.arguments)
            agents[index].backgroundJobs = scan.jobs
            if let date = scan.recheckDate { recheckDate = min(recheckDate ?? date, date) }
        }
        return AgentStore.Fetch(agents: agents, recheckDate: recheckDate)
    }

    /// Reads one terminal's records, and its foreground process and title when it has records.
    private nonisolated static func read(_ candidate: RexAgents.Terminal, from connection: RexConnection) async throws -> RexAgents.Terminal? {
        let session = candidate.sessionId, block = candidate.blockId
        guard let records = try await unlessRefused({ try await connection.programStatus(session: session, block: block) }),
              !records.isEmpty
        else { return nil }
        var terminal = candidate
        terminal.records = records
        async let foreground = unlessRefused { try await connection.foregroundProcess(session: session, block: block) }
        async let title = unlessRefused { try await connection.title(session: session, block: block) }
        switch try await foreground {
        case .some(let process): terminal.foreground = process
        case .none: terminal.foregroundKnown = false
        }
        terminal.title = try await title ?? nil
        return terminal
    }

    /// Runs `call`, and returns nil when rex answers with an error, such as for a block that closed meanwhile.
    /// Connection problems still throw, so a lost connection doesn't look like a server without agents.
    private nonisolated static func unlessRefused<T: Sendable>(_ call: @Sendable () async throws -> T) async throws -> T? {
        do {
            return try await call()
        } catch HerdrError.server {
            return nil
        }
    }

    private func setState(_ newState: State) {
        state = newState
        if case .loaded(let agents) = newState {
            onAgentsChanged?(agents)
        } else {
            onAgentsChanged?([])
        }
    }

    private func apply(_ agents: [Agent], isBaseline: Bool = false) {
        var previous: [Agent]?
        if !isBaseline, case .loaded(let current) = state { previous = current }
        let alerts = AgentAlert.alerts(previous: previous, current: agents)

        if state != .loaded(agents) {
            var countsBefore: String?
            if case .loaded(let current) = state { countsBefore = MenuBarLabel.counts(of: current) }
            setState(.loaded(agents))
            // Messages change with every step an agent takes, so log only when the counts change.
            let counts = MenuBarLabel.counts(of: agents)
            if counts != countsBefore { log.info("rex agents: \(counts, privacy: .public)") }
        }
        if !alerts.isEmpty { onAlerts?(alerts) }
    }

    typealias State = AgentStore.State
}
