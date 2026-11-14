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

        #expect(await store.focus(agent(pane: "w1:p1")))

        let request = try #require(herdr.server.requests(method: "agent.focus").first)
        #expect((request["params"] as? [String: String]) == ["target": "w1:p1"])
    }

    @Test func focusReportsFailureWhenHerdrRefuses() async throws {
        let herdr = try FakeHerdrWithAgents([("w1:p1", "done")])
        defer { herdr.server.stop() }
        let store = AgentStore(client: HerdrClient(socketPath: herdr.server.path), timing: Self.timing)

        #expect(await store.focus(agent(pane: "w1:gone")) == false)
    }

    @Test func focusReportsFailureWhenHerdrIsNotRunning() async {
        let store = AgentStore(client: HerdrClient(socketPath: FakeHerdrServer.temporarySocketPath()), timing: Self.timing)
        #expect(await store.focus(agent(pane: "w1:p1")) == false)
    }

    private func agent(pane: String) -> Agent {
        Agent(
            paneId: pane, workspaceId: "w1", tabId: "w1:t1", agent: "claude", name: nil,
            agentStatus: .done, focused: false, cwd: nil, foregroundCwd: nil, terminalTitleStripped: nil
        )
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
    private(set) var server: FakeHerdrServer!

    var agents: [(pane: String, status: String)] {
        get { lock.withLock { current } }
        set { lock.withLock { current = newValue } }
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
