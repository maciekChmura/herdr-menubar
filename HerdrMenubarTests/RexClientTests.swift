import Foundation
import Testing
@testable import HerdrMenubar

/// The rex client against `FakeRexServer`: the upgrade, the hello, requests, events and a lost connection.
struct RexClientTests {
    @Test func greetsTheServerAndCallsMethods() async throws {
        let server = try FakeRexServer { method, payload in
            #expect(method == "session.list_blocks")
            #expect(payload["session_id"] as? String == "session:1")
            return .result(#"{"blocks":[{"block_id":"block:1","label":"shell","creator_name":"com.superlogical.terminal","placement":"placed","window_id":"window:1"}]}"#)
        }
        defer { server.stop() }

        let connection = try await RexClient(socketPath: server.path).connect()
        defer { connection.close() }
        let blocks = try await connection.blocks(inSession: "session:1")

        #expect(blocks == [RexBlock(blockId: "block:1", label: "shell", creatorName: "com.superlogical.terminal", windowId: "window:1")])
        let hello = try #require(server.hellos.first)
        #expect(hello["type"] as? String == "hello")
        #expect(hello["api_revision"] as? Int == 18)
        #expect((hello["client"] as? [String: Any])?["kind"] as? String == "other", "Not an app: rex do would pick it")
    }

    @Test func callsABlockMethodWithItsShortName() async throws {
        let server = try FakeRexServer { _, _ in
            .result(#"{"records":[\#(FakeRex.record("working", msg: "Running tests"))]}"#)
        }
        defer { server.stop() }

        let connection = try await RexClient(socketPath: server.path).connect()
        defer { connection.close() }
        let records = try await connection.programStatus(session: "session:1", block: "block:1")

        #expect(records.map(\.state) == ["working"])
        #expect(records.first?.msg == "Running tests")
        #expect(records.first?.owner == RexProcess(pid: 100, name: "claude"))
        let request = try #require(server.requests(method: "block.method").first)
        #expect(request["method"] as? String == "program_status")
        #expect(request["block_id"] as? String == "block:1")
        #expect(request["session_id"] as? String == "session:1")
    }

    @Test func reportsTheServersError() async throws {
        let server = try FakeRexServer { _, _ in .error(code: "not_found", message: "block not found") }
        defer { server.stop() }

        let connection = try await RexClient(socketPath: server.path).connect()
        defer { connection.close() }
        await #expect(throws: HerdrError.server(code: "not_found", message: "block not found")) {
            try await connection.focusBlock(session: "session:1", block: "block:9")
        }
    }

    @Test func givesUpOnARequestThatGetsNoAnswer() async throws {
        let server = try FakeRexServer { _, _ in .none }
        defer { server.stop() }

        let connection = try await RexClient(socketPath: server.path, timeout: 0.2).connect()
        defer { connection.close() }
        await #expect(throws: HerdrError.timedOut) { try await connection.sessions() }
    }

    @Test func aMissingSocketMeansRexIsNotRunning() async {
        await #expect(throws: HerdrError.notRunning) {
            try await RexClient(socketPath: FakeHerdrServer.temporarySocketPath()).connect()
        }
    }

    @Test func refusesAServerThatDoesntWelcomeIt() async throws {
        let server = try FakeRexServer(welcome: #"{"type":"response","id":"x","seq":0}"#) { _, _ in .result("{}") }
        defer { server.stop() }

        await #expect(throws: HerdrError.self) { try await RexClient(socketPath: server.path).connect() }
    }

    @Test func deliversEvents() async throws {
        let server = try FakeRexServer { _, _ in .result(#"{"sessions":[]}"#) }
        defer { server.stop() }

        let connection = try await RexClient(socketPath: server.path).connect()
        defer { connection.close() }
        try await connection.attachAll()
        #expect(server.requests(method: "session.attach_all").first?["event_scope"] as? String == "all")

        server.push(FakeRex.serverEvent("client_joined"))
        server.push(FakeRex.sessionEvent("block_closed", session: "session:2", block: "block:5"))
        server.push(FakeRex.blockEvent("program_status_changed", session: "session:2", block: "block:5"))

        var events: [RexEvent] = []
        for try await event in connection.events {
            events.append(event)
            if events.count == 3 { break }
        }
        #expect(events == [
            RexEvent(name: "client_joined", sessionId: nil, blockId: nil),
            RexEvent(name: "block_closed", sessionId: "session:2", blockId: "block:5"),
            RexEvent(name: "program_status_changed", sessionId: "session:2", blockId: "block:5"),
        ])
    }

    @Test func answersThePing() async throws {
        let server = try FakeRexServer { _, _ in .result("{}") }
        defer { server.stop() }

        let connection = try await RexClient(socketPath: server.path).connect()
        defer { connection.close() }
        server.ping([1, 2, 3])

        try await waitUntil("pong") { server.pongs == [[1, 2, 3]] }
    }

    @Test func aLostConnectionEndsEventsAndWaitingRequests() async throws {
        let server = try FakeRexServer { _, _ in .none }
        defer { server.stop() }

        let connection = try await RexClient(socketPath: server.path, timeout: 5).connect()
        defer { connection.close() }
        try await waitUntil("connected") { server.connectionCount == 1 }

        let waiting = Task { try await connection.sessions() }
        try await waitUntil("request sent") { server.requestCount == 1 }
        server.dropConnections()

        await #expect(throws: HerdrError.connectionClosed) { _ = try await waiting.value }
        await #expect(throws: HerdrError.connectionClosed) {
            for try await _ in connection.events {}
        }
        await #expect(throws: HerdrError.connectionClosed) { try await connection.sessions() }
    }

    @Test func findsTheSocketInRexsDefaultPlace() {
        let defaults = UserDefaults(suiteName: "RexClientTests")!
        defaults.removePersistentDomain(forName: "RexClientTests")
        let home = URL(fileURLWithPath: "/Users/me")
        #expect(RexClient.resolveSocketPath(defaults: defaults, home: home) == "/Users/me/Library/Application Support/rex/server.sock")

        defaults.set("/tmp/other.sock", forKey: "RexSocketPath")
        #expect(RexClient.resolveSocketPath(defaults: defaults, home: home) == "/tmp/other.sock")
        defaults.removePersistentDomain(forName: "RexClientTests")
    }
}

/// Waits until `condition` holds, checking every 10 ms. For tests that aren't on the main actor.
func waitUntil(_ what: String, timeout: Duration = .seconds(3), _ condition: () -> Bool) async throws {
    let deadline = ContinuousClock.now + timeout
    while !condition() {
        guard ContinuousClock.now < deadline else {
            throw ConditionTimedOut(description: "Timed out waiting for: \(what)")
        }
        try await Task.sleep(for: .milliseconds(10))
    }
}
