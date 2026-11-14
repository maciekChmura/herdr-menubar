import Darwin
import Foundation
import Testing
@testable import HerdrMenubar

/// Exercises the real socket code against a fake herdr server on a temporary socket.
/// These tests never touch the user's herdr server.
struct HerdrClientTests {
    @Test func listsAgentsFromTheServerReply() async throws {
        let server = try FakeHerdrServer { request in
            let id = request["id"] as? String ?? ""
            return #"{"id":"\#(id)","result":{"type":"agent_list","agents":[{"agent":"claude","agent_status":"blocked","focused":true,"pane_id":"w1:p1","tab_id":"w1:t1","workspace_id":"w1","terminal_id":"term_1","revision":1,"terminal_title_stripped":"Fix tests"}]}}"#
        }
        defer { server.stop() }

        let agents = try await HerdrClient(socketPath: server.path).listAgents()

        #expect(agents.map(\.paneId) == ["w1:p1"])
        #expect(agents.first?.agentStatus == .blocked)
        #expect(agents.first?.displayTitle == "Fix tests")

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
        let server = try FakeHerdrServer { _ in nil }
        defer { server.stop() }

        await #expect(throws: HerdrError.connectionClosed) {
            try await HerdrClient(socketPath: server.path).listAgents()
        }
    }

    @Test func timesOutWhenTheServerNeverReplies() async throws {
        let server = try FakeHerdrServer { _ in
            Thread.sleep(forTimeInterval: 1)
            return nil
        }
        defer { server.stop() }

        var client = HerdrClient(socketPath: server.path)
        client.timeout = 0.2
        await #expect(throws: HerdrError.timedOut) {
            try await client.listAgents()
        }
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

/// Accepts one connection on a temporary Unix socket, reads one request line,
/// and replies with whatever `handler` returns (or closes without replying when it returns nil).
final class FakeHerdrServer: @unchecked Sendable {
    let path: String
    private let listener: Int32
    private let lock = NSLock()
    private var receivedRequests: [[String: Any]] = []

    var requests: [[String: Any]] {
        lock.withLock { receivedRequests }
    }

    static func temporarySocketPath() -> String {
        // Unix socket paths are limited to 104 bytes, so keep the name short.
        NSTemporaryDirectory() + "hm-\(UUID().uuidString.prefix(8)).sock"
    }

    init(handler: @escaping @Sendable ([String: Any]) -> String?) throws {
        path = Self.temporarySocketPath()
        listener = socket(AF_UNIX, SOCK_STREAM, 0)
        var addr = try UnixSocket.address(path)
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(listener, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bound == 0, listen(listener, 1) == 0 else { throw HerdrError.io(errno: errno) }

        Thread.detachNewThread { [self] in
            let connection = accept(listener, nil, nil)
            guard connection >= 0 else { return }
            defer { close(connection) }
            guard let line = try? UnixSocket.readLine(fd: connection),
                  let request = try? JSONSerialization.jsonObject(with: line) as? [String: Any]
            else { return }
            lock.withLock { receivedRequests.append(request) }
            if let reply = handler(request) {
                try? UnixSocket.writeAll(fd: connection, data: Data((reply + "\n").utf8))
            }
        }
    }

    func stop() {
        close(listener)
        unlink(path)
    }
}
