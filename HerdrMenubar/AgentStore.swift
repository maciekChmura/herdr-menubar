import Foundation
import Observation
import OSLog

/// What the app currently knows about herdr's agents, kept in sync with the server.
///
/// See "Keeping state in sync" in `docs/PRD.md`. `agent.list` is the source of truth; events only
/// say when to fetch it again.
@MainActor
@Observable
final class AgentStore {
    enum State: Equatable {
        case loading
        case notRunning
        case failed(String)
        case loaded([Agent])
    }

    struct Timing: Sendable {
        /// How long to wait after an event before fetching, so a burst of events causes one fetch.
        var refreshDebounce: Duration = .milliseconds(100)
        /// Fallback fetch while connected, in case an event was missed.
        var safetyRefreshInterval: Duration = .seconds(30)
        var initialRetryDelay: Duration = .seconds(1)
        var maxRetryDelay: Duration = .seconds(30)
    }

    /// Pane events that take no parameters. Status changes are added per pane.
    static let paneEvents = ["pane.created", "pane.closed", "pane.exited", "pane.agent_detected", "pane.updated"]

    static func subscriptions(forPanes panes: Set<String>) -> [Subscription] {
        paneEvents.map { Subscription(type: $0) }
            + panes.sorted().map { Subscription(type: "pane.agent_status_changed", paneId: $0) }
    }

    private(set) var state: State = .loading
    private let client: HerdrClient
    private let timing: Timing
    @ObservationIgnored private var syncTask: Task<Void, Never>?
    @ObservationIgnored private var sessionSubscribed = false
    private let log = Logger(subsystem: "io.github.maciekchmura.HerdrMenubar", category: "herdr")

    init(client: HerdrClient, timing: Timing = Timing()) {
        self.client = client
        self.timing = timing
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

    private func syncUntilCancelled() async {
        var retryDelay = timing.initialRetryDelay
        while !Task.isCancelled {
            sessionSubscribed = false
            do {
                try await runSession()
                // The set of agent panes changed: subscribe again right away.
                retryDelay = timing.initialRetryDelay
                continue
            } catch is CancellationError {
                return
            } catch HerdrError.notRunning {
                if state != .notRunning {
                    log.info("herdr server is not running at \(self.client.socketPath, privacy: .public)")
                }
                state = .notRunning
            } catch {
                log.error("Lost the herdr connection: \(String(describing: error), privacy: .public)")
                // Keep showing the last agents we had; the next attempt corrects them.
                if case .loaded = state {} else { state = .failed(String(describing: error)) }
            }

            if sessionSubscribed { retryDelay = timing.initialRetryDelay }
            try? await Task.sleep(for: retryDelay)
            retryDelay = min(retryDelay * 2, timing.maxRetryDelay)
        }
    }

    /// Lists the agents, subscribes to their events, and refetches on every event until the
    /// subscription drops (throws) or the set of agent panes changes (returns).
    private func runSession() async throws {
        apply(try await client.listAgents())
        guard case .loaded(let agents) = state else { return }
        let panes = Set(agents.map(\.paneId))

        let events = try await client.subscribe(Self.subscriptions(forPanes: panes))
        sessionSubscribed = true
        log.info("Subscribed to events for \(panes.count) agent panes")

        let (triggers, trigger) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        // Fetch once more now: a change between the first fetch and the subscription would otherwise be missed.
        trigger.yield()

        let client = client
        let timing = timing
        let log = log
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                for try await kind in events {
                    log.debug("Event \(kind, privacy: .public)")
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
            group.addTask { [weak self] in
                // Triggers that arrive while waiting or fetching collapse into one buffered trigger.
                for await _ in triggers {
                    try await Task.sleep(for: timing.refreshDebounce)
                    let agents = try await client.listAgents()
                    guard let self else { return }
                    await self.apply(agents)
                    if Set(agents.map(\.paneId)) != panes { return }
                }
            }
            try await group.next()
            group.cancelAll()
        }
    }

    private func apply(_ agents: [Agent]) {
        guard state != .loaded(agents) else { return }
        state = .loaded(agents)
        log.info("Agents: \(MenuBarLabel.counts(of: agents), privacy: .public)")
    }
}
