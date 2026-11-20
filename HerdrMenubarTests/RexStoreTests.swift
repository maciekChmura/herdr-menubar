import Foundation
import Testing
@testable import HerdrMenubar

/// The rex sync loop against `FakeRexServer`: initial load, refetch on the events that matter, reconnect,
/// alerts, clicking an agent and background jobs.
@MainActor
struct RexStoreTests {
    static let timing = AgentStoreTests.timing

    @Test func loadsTheTerminalsThatReportAStatus() async throws {
        let rex = try FakeRexWithTerminals([
            .init(block: "block:1", records: [FakeRex.record("working", msg: "Running tests")], title: "Fix login"),
            .init(block: "block:2", records: []),
            .init(session: "session:2", block: "block:3", records: [FakeRex.record("blocked")]),
        ])
        let store = RexStore(client: RexClient(socketPath: rex.server.path), timing: Self.timing)
        store.start()
        defer { store.stop(); rex.server.stop() }

        try await eventually("agents loaded") { statuses(store) == [.working, .blocked] }
        let agents = try #require(agents(store))
        #expect(agents.map(\.paneId) == ["block:1", "block:3"], "Sessions in order, then blocks")
        #expect(agents.first?.displayTitle == "Fix login")
        #expect(agents.first?.message == "Running tests")
        #expect(agents.first?.folderName == "project")
        #expect(rex.server.requests(method: "session.attach_all").first?["event_scope"] as? String == "all")
        #expect(rex.server.requests(method: "block.method").filter { $0["block_id"] as? String == "block:2" }.count == 1,
                "A terminal without records isn't asked for its process or title")
    }

    @Test func refetchesOnStatusEventsButNotOnClientEvents() async throws {
        let rex = try FakeRexWithTerminals([.init(block: "block:1", records: [FakeRex.record("working")])])
        let store = RexStore(client: RexClient(socketPath: rex.server.path), timing: Self.timing)
        store.start()
        defer { store.stop(); rex.server.stop() }

        try await eventually("agents loaded") { statuses(store) == [.working] }
        rex.terminals[0].records = [FakeRex.record("blocked")]

        // Every rex command anyone runs connects as a client.
        rex.server.push(FakeRex.serverEvent("client_joined"))
        rex.server.push(FakeRex.sessionEvent("client_connected"))
        rex.server.push(FakeRex.blockEvent("size_changed"))
        try await Task.sleep(for: .milliseconds(100))
        #expect(statuses(store) == [.working], "Nothing should refetch without a status or structure event")

        rex.server.push(FakeRex.blockEvent("program_status_changed"))
        try await eventually("status change picked up") { statuses(store) == [.blocked] }
    }

    @Test func dropsAnAgentWhoseProgramLeft() async throws {
        let rex = try FakeRexWithTerminals([.init(block: "block:1", records: [FakeRex.record("idle")])])
        let store = RexStore(client: RexClient(socketPath: rex.server.path), timing: Self.timing)
        store.start()
        defer { store.stop(); rex.server.stop() }

        try await eventually("agents loaded") { statuses(store) == [.idle] }

        // Claude Code exits; the shell is back in the foreground, and rex keeps the idle record.
        rex.terminals[0].foreground = (50, "zsh", "/Users/me")
        rex.server.push(FakeRex.blockEvent("process_changed"))
        try await eventually("agent gone") { statuses(store) == [] }
    }

    @Test func reconnectsAfterTheConnectionDrops() async throws {
        let rex = try FakeRexWithTerminals([.init(block: "block:1", records: [FakeRex.record("working")])])
        let store = RexStore(client: RexClient(socketPath: rex.server.path), timing: Self.timing)
        store.start()
        defer { store.stop(); rex.server.stop() }

        try await eventually("connected") { rex.server.connectionCount == 1 && statuses(store) == [.working] }
        rex.terminals[0].records = [FakeRex.record("done")]
        rex.server.dropConnections()

        try await eventually("reconnected") { rex.server.requests(method: "session.attach_all").count == 2 }
        try await eventually("state read again") { statuses(store) == [.done] }
    }

    @Test func saysSoWhenRexIsNotRunning() async throws {
        let store = RexStore(client: RexClient(socketPath: FakeHerdrServer.temporarySocketPath()), timing: Self.timing)
        store.start()
        defer { store.stop() }

        try await eventually("not running") { store.state == .notRunning }
    }

    @Test func alertsOnChangesButNotOnWhatWasThereAtLaunch() async throws {
        let rex = try FakeRexWithTerminals([
            .init(block: "block:1", records: [FakeRex.record("blocked")]),
            .init(block: "block:2", records: [FakeRex.record("working")]),
        ])
        let store = RexStore(client: RexClient(socketPath: rex.server.path), timing: Self.timing)
        let log = AlertLog()
        store.onAlerts = { log.alerts += $0 }
        store.start()
        defer { store.stop(); rex.server.stop() }

        try await eventually("agents loaded") { statuses(store) == [.blocked, .working] }
        rex.terminals[1].records = [FakeRex.record("error", msg: "Tests failed")]
        rex.server.push(FakeRex.blockEvent("program_status_changed", block: "block:2"))

        try await eventually("alert") { log.alerts.count == 1 }
        #expect(log.alerts.first?.kind == .done)
        #expect(log.alerts.first?.agent.paneId == "block:2")
    }

    @Test func clickingAnAgentFocusesItsTerminalAndAsksTheLocalMacAppToShowIt() async throws {
        let rex = try FakeRexWithTerminals([.init(session: "session:7", block: "block:1", records: [FakeRex.record("done")])])
        rex.appClients = [
            FakeRexWithTerminals.app("client:mac"),
            FakeRexWithTerminals.app("client:phone", platform: "ios", transport: "tailscale"),
            FakeRexWithTerminals.app("client:other-mac", transport: "tailscale"),
        ]
        let store = RexStore(client: RexClient(socketPath: rex.server.path), timing: Self.timing)
        store.start()
        defer { store.stop(); rex.server.stop() }
        try await eventually("agents loaded") { statuses(store) == [.done] }

        let focused = await store.focus(paneId: "block:1")
        #expect(focused)

        let focus = try #require(rex.server.requests(method: "session.focus_block").first)
        #expect(focus["session_id"] as? String == "session:7")
        #expect(focus["block_id"] as? String == "block:1")
        let performs = rex.server.requests(method: "client.perform")
        #expect(performs.map { $0["client_id"] as? String } == ["client:mac"])
        #expect(performs.first?["action"] as? String == "session.select")
        #expect((performs.first?["args"] as? [String: Any])?["session_id"] as? String == "session:7")
    }

    @Test func clickingStillWorksWhenRexAppRefusesRemoteControl() async throws {
        let rex = try FakeRexWithTerminals([.init(block: "block:1", records: [FakeRex.record("done")])])
        rex.appClients = [FakeRexWithTerminals.app("client:mac")]
        rex.performs = .error(code: "refused", message: "Remote Control is off")
        let store = RexStore(client: RexClient(socketPath: rex.server.path), timing: Self.timing)
        store.start()
        defer { store.stop(); rex.server.stop() }
        try await eventually("agents loaded") { statuses(store) == [.done] }

        let focused = await store.focus(paneId: "block:1")
        #expect(focused, "The terminal is focused; only switching Rex.app's session failed")
        let missing = await store.focus(paneId: "block:9")
        #expect(!missing, "No such agent")
    }

    @Test func findsTheBackgroundJobsOfAnAgentWaitingForInput() async throws {
        let rex = try FakeRexWithTerminals([
            .init(block: "block:1", records: [FakeRex.record("idle")]),
            .init(block: "block:2", records: [FakeRex.record("working", owner: (200, "claude"))], foreground: (200, "claude", "/Users/me/dev/b")),
        ])
        let now = Date()
        let processes = ProcessSource(
            list: {
                [
                    RunningProcess(pid: 100, parentPid: 1, groupId: 100, startDate: now - 3600),
                    RunningProcess(pid: 150, parentPid: 100, groupId: 150, startDate: now - 120),
                    RunningProcess(pid: 200, parentPid: 1, groupId: 200, startDate: now - 3600),
                    RunningProcess(pid: 250, parentPid: 200, groupId: 250, startDate: now - 120),
                ]
            },
            arguments: { _ in ["/bin/sleep", "240"] }
        )
        let store = RexStore(client: RexClient(socketPath: rex.server.path), timing: Self.timing, processes: processes)
        store.start()
        defer { store.stop(); rex.server.stop() }

        try await eventually("agents loaded") { agents(store)?.count == 2 }
        #expect(agents(store)?.map { $0.backgroundJobs.map(\.pid) } == [[150], []], "A working agent's commands are its work")
    }

    private func agents(_ store: RexStore) -> [Agent]? {
        guard case .loaded(let agents) = store.state else { return nil }
        return agents
    }

    private func statuses(_ store: RexStore) -> [AgentStatus]? {
        agents(store)?.map(\.agentStatus)
    }
}
