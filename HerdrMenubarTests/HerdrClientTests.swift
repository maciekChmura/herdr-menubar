import Darwin
import Foundation
import Testing
@testable import HerdrMenubar

/// Exercises the real socket code against `FakeHerdrServer`.
struct HerdrClientTests {
    @Test func listsAgentsFromTheServerReply() async throws {
        let server = try FakeHerdrServer { request in
            .reply(FakeHerdr.agentList(id: request["id"] as? String ?? "", [("w1:p1", "blocked")]))
        }
        defer { server.stop() }

        let agents = try await HerdrClient(socketPath: server.path).listAgents()

        #expect(agents.map(\.paneId) == ["w1:p1"])
        #expect(agents.first?.agentStatus == .blocked)
        #expect(agents.first?.displayTitle == "Task in w1:p1")

        let request = try #require(server.requests.first)
        #expect(request["method"] as? String == "agent.list")
        #expect((request["params"] as? [String: Any])?.isEmpty == true)
        #expect((request["id"] as? String)?.isEmpty == false)
    }

    @Test func reportsNotRunningWhenTheSocketFileIsMissing() async {
        let path = FakeHerdrServer.temporarySocketPath()
        await #expect(throws: HerdrError.notRunning) {
            try await HerdrClient(socketPath: path).listAgents()
        }
    }

    @Test func reportsNotRunningWhenNothingListensOnTheSocket() async throws {
        // A socket file left behind by a server that's gone: connecting is refused.
        let path = FakeHerdrServer.temporarySocketPath()
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        var addr = try UnixSocket.address(path)
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        try #require(bound == 0)
        close(fd)
        defer { unlink(path) }

        await #expect(throws: HerdrError.notRunning) {
            try await HerdrClient(socketPath: path).listAgents()
        }
    }

    @Test func reportsAConnectionClosedWithoutAReply() async throws {
        let server = try FakeHerdrServer { _ in .close }
        defer { server.stop() }

        await #expect(throws: HerdrError.connectionClosed) {
            try await HerdrClient(socketPath: server.path).listAgents()
        }
    }

    @Test func timesOutWhenTheServerNeverReplies() async throws {
        let server = try FakeHerdrServer { _ in
            Thread.sleep(forTimeInterval: 1)
            return .close
        }
        defer { server.stop() }

        var client = HerdrClient(socketPath: server.path)
        client.timeout = 0.2
        await #expect(throws: HerdrError.timedOut) {
            try await client.listAgents()
        }
    }

    @Test func subscriptionSendsTheRequestedSubscriptions() async throws {
        let server = try FakeHerdrServer { request in
            .replyAndHold(FakeHerdr.subscriptionStarted(id: request["id"] as? String ?? ""))
        }
        defer { server.stop() }

        _ = try await HerdrClient(socketPath: server.path).subscribe([
            Subscription(type: "pane.created"),
            Subscription(type: "pane.agent_status_changed", paneId: "w1:p1"),
        ])

        let request = try #require(server.requests(method: "events.subscribe").first)
        let subscriptions = (request["params"] as? [String: Any])?["subscriptions"] as? [[String: String]]
        #expect(subscriptions == [
            ["type": "pane.created"],
            ["type": "pane.agent_status_changed", "pane_id": "w1:p1"],
        ])
    }

    @Test func subscriptionYieldsEventKindsUntilTheServerCloses() async throws {
        let server = try FakeHerdrServer { request in
            .replyAndHold(FakeHerdr.subscriptionStarted(id: request["id"] as? String ?? ""))
        }
        defer { server.stop() }

        let events = try await HerdrClient(socketPath: server.path).subscribe([Subscription(type: "pane.updated")])
        // Both lines can arrive in one read; neither may be lost.
        server.push(FakeHerdr.event("pane.agent_status_changed", pane: "w1:p1") + "\n" + FakeHerdr.event("pane.updated", pane: "w1:p1"))

        var iterator = events.makeAsyncIterator()
        #expect(try await iterator.next() == "pane.agent_status_changed")
        #expect(try await iterator.next() == "pane.updated")

        server.dropHeldConnections()
        do {
            _ = try await iterator.next()
            Issue.record("Expected the stream to end with connectionClosed")
        } catch {
            #expect(error as? HerdrError == .connectionClosed)
        }
    }

    @Test func subscriptionThrowsTheServerError() async throws {
        let server = try FakeHerdrServer { request in
            .reply(FakeHerdr.error(id: request["id"] as? String ?? "", code: "invalid_params", message: "bad subscription"))
        }
        defer { server.stop() }

        await #expect(throws: HerdrError.server(code: "invalid_params", message: "bad subscription")) {
            _ = try await HerdrClient(socketPath: server.path).subscribe([Subscription(type: "pane.updated")])
        }
    }

    @Test func asksForAPanesForegroundProcessGroup() async throws {
        let server = try FakeHerdrServer { request in
            .reply(FakeHerdr.processInfo(id: request["id"] as? String ?? "", pane: "w1:p1", group: 4242))
        }
        defer { server.stop() }

        let group = try await HerdrClient(socketPath: server.path).foregroundProcessGroup(ofPane: "w1:p1")

        #expect(group == 4242)
        let request = try #require(server.requests(method: "pane.process_info").first)
        #expect((request["params"] as? [String: String]) == ["pane_id": "w1:p1"])
    }

    @Test func resolvesTheSocketPathInOrderOfPrecedence() throws {
        let defaults = try #require(UserDefaults(suiteName: "HerdrClientTests-\(UUID().uuidString)"))
        let home = URL(fileURLWithPath: "/Users/me")

        #expect(HerdrClient.resolveSocketPath(defaults: defaults, environment: [:], home: home)
            == "/Users/me/.config/herdr/herdr.sock")
        #expect(HerdrClient.resolveSocketPath(defaults: defaults, environment: ["HERDR_SOCKET_PATH": "/env.sock"], home: home)
            == "/env.sock")
        defaults.set("/defaults.sock", forKey: "HerdrSocketPath")
        #expect(HerdrClient.resolveSocketPath(defaults: defaults, environment: ["HERDR_SOCKET_PATH": "/env.sock"], home: home)
            == "/defaults.sock")
    }
}
