import Foundation
import Testing
@testable import HerdrMenubar

/// The sync loop against `FakeHerdrServer`: initial load, refetch on events, resubscribe, reconnect.
@MainActor
struct AgentStoreTests {
    /// Short delays so tests run fast. The safety refresh is pushed out of the way so that only
    /// events can cause a refetch.
    static let timing = AgentStore.Timing(
        refreshDebounce: .milliseconds(10),
        safetyRefreshInterval: .seconds(3600),
        initialRetryDelay: .milliseconds(20),
        maxRetryDelay: .milliseconds(100)
    )

    @Test func loadsAgentsAndSubscribesToEachAgentPane() async throws {
        let herdr = try FakeHerdrWithAgents([("w1:p1", "working"), ("w1:p2", "idle")])
        let store = AgentStore(client: HerdrClient(socketPath: herdr.server.path), timing: Self.timing)
        store.start()
        defer { store.stop(); herdr.server.stop() }

        try await eventually("agents loaded") { statuses(store) == [.working, .idle] }
        try await eventually("subscribed") { herdr.server.heldConnectionCount == 1 }

        let subscribe = try #require(herdr.server.requests(method: "events.subscribe").first)
        #expect(subscriptionKeys(subscribe) == [
            "pane.created", "pane.closed", "pane.exited", "pane.agent_detected", "pane.updated", "pane.focused",
            "pane.agent_status_changed w1:p1", "pane.agent_status_changed w1:p2",
        ])
    }

    @Test func refetchesWhenAnEventArrives() async throws {
        let herdr = try FakeHerdrWithAgents([("w1:p1", "working")])
        let store = AgentStore(client: HerdrClient(socketPath: herdr.server.path), timing: Self.timing)
        store.start()
        defer { store.stop(); herdr.server.stop() }

        // The first fetch, then the one right after subscribing.
        try await eventually("settled after subscribing") {
            herdr.server.heldConnectionCount == 1 && herdr.server.requests(method: "agent.list").count == 2
        }

        herdr.agents = [("w1:p1", "blocked")]
        try await Task.sleep(for: .milliseconds(100))
        #expect(statuses(store) == [.working], "Nothing should refetch without an event")

        herdr.server.push(FakeHerdr.event("pane.agent_status_changed", pane: "w1:p1"))
        try await eventually("status change picked up") { statuses(store) == [.blocked] }
    }

    @Test func resubscribesWhenTheSetOfAgentPanesChanges() async throws {
        let herdr = try FakeHerdrWithAgents([("w1:p1", "working")])
        let store = AgentStore(client: HerdrClient(socketPath: herdr.server.path), timing: Self.timing)
        store.start()
        defer { store.stop(); herdr.server.stop() }

        try await eventually("settled after subscribing") {
            herdr.server.heldConnectionCount == 1 && herdr.server.requests(method: "agent.list").count == 2
        }

        herdr.agents = [("w1:p1", "working"), ("w1:p3", "working")]
        herdr.server.push(FakeHerdr.event("pane.agent_detected", pane: "w1:p3"))

        try await eventually("subscribed again") { herdr.server.requests(method: "events.subscribe").count == 2 }
        let latest = try #require(herdr.server.requests(method: "events.subscribe").last)
        #expect(subscriptionKeys(latest).contains("pane.agent_status_changed w1:p3"))
        #expect(statuses(store) == [.working, .working])
    }

    @Test func reconnectsAfterTheSubscriptionDrops() async throws {
        let herdr = try FakeHerdrWithAgents([("w1:p1", "working")])
        let store = AgentStore(client: HerdrClient(socketPath: herdr.server.path), timing: Self.timing)
        store.start()
        defer { store.stop(); herdr.server.stop() }

        try await eventually("subscribed") { herdr.server.heldConnectionCount == 1 }

        herdr.server.dropHeldConnections()

        try await eventually("subscribed again") {
            herdr.server.requests(method: "events.subscribe").count == 2 && herdr.server.heldConnectionCount == 1
        }
        #expect(statuses(store) == [.working])
    }

    @Test func showsNotRunningUntilTheServerStarts() async throws {
        let path = FakeHerdrServer.temporarySocketPath()
        let store = AgentStore(client: HerdrClient(socketPath: path), timing: Self.timing)
        store.start()
        defer { store.stop() }

        try await eventually("not running") { store.state == .notRunning }

        let herdr = try FakeHerdrWithAgents([("w1:p1", "done")], path: path)
        defer { herdr.server.stop() }
        try await eventually("recovered") { statuses(store) == [.done] }
    }

    @Test func focusSendsThePaneIDAsTheTarget() async throws {
        let herdr = try FakeHerdrWithAgents([("w1:p1", "done")])
        defer { herdr.server.stop() }
        let store = AgentStore(client: HerdrClient(socketPath: herdr.server.path), timing: Self.timing)

        #expect(await store.focus(paneId: "w1:p1"))

        let request = try #require(herdr.server.requests(method: "agent.focus").first)
        #expect((request["params"] as? [String: String]) == ["target": "w1:p1"])
    }

    @Test func focusReportsFailureWhenHerdrRefuses() async throws {
        let herdr = try FakeHerdrWithAgents([("w1:p1", "done")])
        defer { herdr.server.stop() }
        let store = AgentStore(client: HerdrClient(socketPath: herdr.server.path), timing: Self.timing)

        #expect(await store.focus(paneId: "w1:gone") == false)
    }

    @Test func focusReportsFailureWhenHerdrIsNotRunning() async {
        let store = AgentStore(client: HerdrClient(socketPath: FakeHerdrServer.temporarySocketPath()), timing: Self.timing)
        #expect(await store.focus(paneId: "w1:p1") == false)
    }

    @Test func alertsOnceWhenAnAgentFinishesButNotForStatesAtLaunch() async throws {
        let herdr = try FakeHerdrWithAgents([("w1:p1", "working"), ("w1:p2", "done")])
        let store = AgentStore(client: HerdrClient(socketPath: herdr.server.path), timing: Self.timing)
        let received = AlertLog()
        store.onAlerts = { received.alerts += $0 }
        store.start()
        defer { store.stop(); herdr.server.stop() }

        try await eventually("settled after subscribing") {
            herdr.server.heldConnectionCount == 1 && herdr.server.requests(method: "agent.list").count == 2
        }
        #expect(received.alerts.isEmpty, "An agent that was already done at launch doesn't notify")

        herdr.agents = [("w1:p1", "done"), ("w1:p2", "done")]
        herdr.server.push(FakeHerdr.event("pane.agent_status_changed", pane: "w1:p1"))
        try await eventually("alerted") { !received.alerts.isEmpty }

        // Another event without a change must not repeat the alert.
        herdr.server.push(FakeHerdr.event("pane.focused", pane: "w1:p1"))
        try await eventually("refetched") { herdr.server.requests(method: "agent.list").count == 4 }
        #expect(received.alerts.map(\.agent.paneId) == ["w1:p1"])
        #expect(received.alerts.map(\.kind) == [.done])
    }

    @Test func doesNotAlertForChangesMadeWhileDisconnected() async throws {
        let herdr = try FakeHerdrWithAgents([("w1:p1", "working")])
        let store = AgentStore(client: HerdrClient(socketPath: herdr.server.path), timing: Self.timing)
        let received = AlertLog()
        store.onAlerts = { received.alerts += $0 }
        store.start()
        defer { store.stop(); herdr.server.stop() }

        try await eventually("settled after subscribing") {
            herdr.server.heldConnectionCount == 1 && herdr.server.requests(method: "agent.list").count == 2
        }

        herdr.agents = [("w1:p1", "done")]
        herdr.server.dropHeldConnections()
        try await eventually("reconnected and settled") {
            herdr.server.heldConnectionCount == 1 && herdr.server.requests(method: "agent.list").count == 4
        }
        #expect(received.alerts.isEmpty, "The first fetch after a reconnect only sets the baseline")
        #expect(statuses(store) == [.done])

        // Changes after the reconnect notify again.
        herdr.agents = [("w1:p1", "blocked")]
        herdr.server.push(FakeHerdr.event("pane.agent_status_changed", pane: "w1:p1"))
        try await eventually("alerted") { !received.alerts.isEmpty }
        #expect(received.alerts.map(\.kind) == [.blocked])
    }

    @Test func findsTheBackgroundJobsOfAgentsWaitingForInput() async throws {
        let herdr = try FakeHerdrWithAgents([("w1:p1", "done"), ("w1:p2", "working"), ("w1:p3", "idle"), ("w1:p4", "idle")])
        // w1:p4 has no process info, like a pane herdr can't inspect.
        herdr.processGroups = ["w1:p1": 100, "w1:p2": 200, "w1:p3": 300]
        let now = Date()
        let processes = ProcessSource(
            list: {
                [
                    RunningProcess(pid: 100, parentPid: 1, groupId: 100, startDate: now - 3600),
                    RunningProcess(pid: 101, parentPid: 100, groupId: 100, startDate: now - 3600), // an MCP server
                    RunningProcess(pid: 150, parentPid: 100, groupId: 150, startDate: now - 120),  // the job's shell
                    RunningProcess(pid: 151, parentPid: 150, groupId: 150, startDate: now - 120),  // what it runs
                    RunningProcess(pid: 200, parentPid: 1, groupId: 200, startDate: now - 3600),
                    RunningProcess(pid: 250, parentPid: 200, groupId: 250, startDate: now - 60),   // the working agent's command
                    RunningProcess(pid: 300, parentPid: 1, groupId: 300, startDate: now - 3600),
                ]
            },
            arguments: { $0 == 151 ? ["/usr/local/bin/node", "/opt/homebrew/bin/npm", "test"] : ["/bin/zsh"] }
        )
        let store = AgentStore(client: HerdrClient(socketPath: herdr.server.path), timing: Self.timing, processes: processes)
        store.start()
        defer { store.stop(); herdr.server.stop() }

        try await eventually("agents loaded") { agents(store)?.count == 4 }

        #expect(agents(store)?.map(\.backgroundJobs) == [
            [BackgroundJob(pid: 150, command: "npm test", startDate: now - 120)], [], [], [],
        ])
        let asked = herdr.server.requests(method: "pane.process_info").compactMap { ($0["params"] as? [String: String])?["pane_id"] }
        #expect(!asked.contains("w1:p2"), "A working agent's commands are its work, so there's no need to ask")
        #expect(Set(asked) == ["w1:p1", "w1:p3", "w1:p4"])
    }

    @Test func looksAgainWhenAJobIsTooYoungToCount() async throws {
        let herdr = try FakeHerdrWithAgents([("w1:p1", "done")])
        herdr.processGroups = ["w1:p1": 100]
        // Old enough a moment from now.
        let jobStart = Date() - BackgroundJobs.minimumAge + 0.4
        let processes = ProcessSource(
            list: {
                [
                    RunningProcess(pid: 100, parentPid: 1, groupId: 100, startDate: jobStart - 3600),
                    RunningProcess(pid: 150, parentPid: 100, groupId: 150, startDate: jobStart),
                ]
            },
            arguments: { _ in ["/bin/sleep", "240"] }
        )
        let store = AgentStore(client: HerdrClient(socketPath: herdr.server.path), timing: Self.timing, processes: processes)
        store.start()
        defer { store.stop(); herdr.server.stop() }

        try await eventually("agents loaded") { agents(store)?.count == 1 }
        #expect(agents(store)?.first?.backgroundJobs.isEmpty == true, "Too young to count yet")

        // No event arrives, and the safety refresh is an hour away.
        try await eventually("job found") { agents(store)?.first?.backgroundJobs.map(\.pid) == [150] }
    }

    @Test func aJobThatEndsLeavesTheAgentOnTheNextFetch() async throws {
        let herdr = try FakeHerdrWithAgents([("w1:p1", "done")])
        herdr.processGroups = ["w1:p1": 100]
        let table = ProcessTableBox([
            RunningProcess(pid: 100, parentPid: 1, groupId: 100, startDate: Date() - 3600),
            RunningProcess(pid: 150, parentPid: 100, groupId: 150, startDate: Date() - 60),
        ])
        let processes = ProcessSource(list: { table.processes }, arguments: { _ in ["/bin/sleep", "240"] })
        let store = AgentStore(client: HerdrClient(socketPath: herdr.server.path), timing: Self.timing, processes: processes)
        store.start()
        defer { store.stop(); herdr.server.stop() }

        try await eventually("job found") { agents(store)?.first?.backgroundJobs.count == 1 }

        // The job ends and the agent wakes up to read its output.
        table.processes.removeLast()
        herdr.agents = [("w1:p1", "working")]
        herdr.server.push(FakeHerdr.event("pane.agent_status_changed", pane: "w1:p1"))
        try await eventually("job gone") { agents(store)?.first?.backgroundJobs.isEmpty == true }
        #expect(statuses(store) == [.working])
    }

    private func agents(_ store: AgentStore) -> [Agent]? {
        guard case .loaded(let agents) = store.state else { return nil }
        return agents
    }

    private func statuses(_ store: AgentStore) -> [AgentStatus]? {
        guard case .loaded(let agents) = store.state else { return nil }
        return agents.map(\.agentStatus)
    }

    /// The subscriptions in an `events.subscribe` request, as "type" or "type pane_id".
    private func subscriptionKeys(_ request: [String: Any]) -> [String] {
        let subscriptions = (request["params"] as? [String: Any])?["subscriptions"] as? [[String: String]] ?? []
        return subscriptions.map { [$0["type"], $0["pane_id"]].compactMap { $0 }.joined(separator: " ") }
    }
}

/// A fake herdr whose agent list the test can change. Subscriptions are held open.
final class FakeHerdrWithAgents: @unchecked Sendable {
    private let lock = NSLock()
    private var current: [(pane: String, status: String)]
    private var groups: [String: Int32] = [:]
    private(set) var server: FakeHerdrServer!

    var agents: [(pane: String, status: String)] {
        get { lock.withLock { current } }
        set { lock.withLock { current = newValue } }
    }

    /// The foreground process group `pane.process_info` reports for each pane. Other panes get an error.
    var processGroups: [String: Int32] {
        get { lock.withLock { groups } }
        set { lock.withLock { groups = newValue } }
    }

    init(_ agents: [(pane: String, status: String)], path: String = FakeHerdrServer.temporarySocketPath()) throws {
        current = agents
        server = try FakeHerdrServer(path: path) { [unowned self] request in
            let id = request["id"] as? String ?? ""
            switch request["method"] as? String {
            case "agent.list":
                return .reply(FakeHerdr.agentList(id: id, self.agents))
            case "events.subscribe":
                return .replyAndHold(FakeHerdr.subscriptionStarted(id: id))
            case "pane.process_info":
                let pane = (request["params"] as? [String: Any])?["pane_id"] as? String ?? ""
                guard let group = self.processGroups[pane] else {
                    return .reply(FakeHerdr.error(id: id, code: "pane_not_found", message: "pane not found"))
                }
                return .reply(FakeHerdr.processInfo(id: id, pane: pane, group: group))
            case "agent.focus":
                // Like herdr: an unknown target is an error.
                let target = (request["params"] as? [String: Any])?["target"] as? String
                guard self.agents.contains(where: { $0.pane == target }) else {
                    return .reply(FakeHerdr.error(id: id, code: "agent_not_found", message: "agent target not found"))
                }
                return .reply(#"{"id":"\#(id)","result":{"type":"ok"}}"#)
            default:
                return .reply(FakeHerdr.error(id: id, code: "unknown_method", message: "not faked"))
            }
        }
    }
}

/// A process table a test can change while the store reads it.
final class ProcessTableBox: @unchecked Sendable {
    private let lock = NSLock()
    private var current: [RunningProcess]

    init(_ processes: [RunningProcess]) {
        current = processes
    }

    var processes: [RunningProcess] {
        get { lock.withLock { current } }
        set { lock.withLock { current = newValue } }
    }
}

@MainActor
final class AlertLog {
    var alerts: [AgentAlert] = []
}

struct ConditionTimedOut: Error, CustomStringConvertible {
    let description: String
}

/// Waits until `condition` holds, checking every 10 ms.
@MainActor
func eventually(
    _ what: String,
    timeout: Duration = .seconds(3),
    _ condition: () -> Bool
) async throws {
    let deadline = ContinuousClock.now + timeout
    while !condition() {
        guard ContinuousClock.now < deadline else {
            throw ConditionTimedOut(description: "Timed out waiting for: \(what)")
        }
        try await Task.sleep(for: .milliseconds(10))
    }
}
