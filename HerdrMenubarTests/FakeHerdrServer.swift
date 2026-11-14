import Darwin
import Foundation
@testable import HerdrMenubar

/// A stand-in herdr server on a temporary Unix socket, so tests never touch the user's real one.
/// For each connection it reads one request line and lets `handler` decide what to do.
final class FakeHerdrServer: @unchecked Sendable {
    enum Reply {
        /// Write this line, then close the connection, like an ordinary herdr request.
        case reply(String)
        /// Write this line and keep the connection open, like a subscription.
        /// Use `push(_:)` to send events on it and `dropHeldConnections()` to close it.
        case replyAndHold(String)
        /// Close the connection without replying.
        case close
    }

    let path: String
    private let listener: Int32
    private let handler: @Sendable ([String: Any]) -> Reply
    private let lock = NSLock()
    private var receivedRequests: [[String: Any]] = []
    private var held: [Int32] = []
    private var stopped = false
    private let acceptLoopDone = DispatchSemaphore(value: 0)

    var requests: [[String: Any]] {
        lock.withLock { receivedRequests }
    }

    func requests(method: String) -> [[String: Any]] {
        requests.filter { $0["method"] as? String == method }
    }

    var heldConnectionCount: Int {
        lock.withLock { held.count }
    }

    static func temporarySocketPath() -> String {
        // Unix socket paths are limited to 104 bytes, so keep the name short.
        NSTemporaryDirectory() + "hm-\(UUID().uuidString.prefix(8)).sock"
    }

    init(
        path: String = FakeHerdrServer.temporarySocketPath(),
        handler: @escaping @Sendable ([String: Any]) -> Reply
    ) throws {
        self.path = path
        self.handler = handler
        listener = socket(AF_UNIX, SOCK_STREAM, 0)
        var addr = try UnixSocket.address(path)
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(listener, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bound == 0, listen(listener, 16) == 0 else { throw HerdrError.io(errno: errno) }

        Thread.detachNewThread { [self] in
            defer { acceptLoopDone.signal() }
            while true {
                let connection = accept(listener, nil, nil)
                if lock.withLock({ stopped }) {
                    if connection >= 0 { close(connection) }
                    return
                }
                guard connection >= 0 else {
                    if errno == EINTR { continue }
                    return
                }
                Thread.detachNewThread { self.serve(connection) }
            }
        }
    }

    /// Writes `line` to every held connection.
    func push(_ line: String) {
        lock.withLock {
            for fd in held {
                try? UnixSocket.writeAll(fd: fd, data: Data((line + "\n").utf8))
            }
        }
    }

    func dropHeldConnections() {
        lock.withLock {
            held.forEach { close($0) }
            held.removeAll()
        }
    }

    func stop() {
        lock.withLock { stopped = true }
        // Closing the listener doesn't wake a thread blocked in accept() on macOS, so connect once to wake it.
        if let fd = try? UnixSocket.connect(path: path, timeout: 1) { close(fd) }
        _ = acceptLoopDone.wait(timeout: .now() + 2)
        close(listener)
        dropHeldConnections()
        unlink(path)
    }

    private func serve(_ connection: Int32) {
        // Writing to a connection the client already closed must not kill the test run with SIGPIPE.
        var on: Int32 = 1
        setsockopt(connection, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))

        guard let line = try? UnixSocket.readLine(fd: connection),
              let request = try? JSONSerialization.jsonObject(with: line) as? [String: Any]
        else {
            close(connection)
            return
        }
        lock.withLock { receivedRequests.append(request) }

        switch handler(request) {
        case .reply(let text):
            try? UnixSocket.writeAll(fd: connection, data: Data((text + "\n").utf8))
            close(connection)
        case .replyAndHold(let text):
            // Hold it before replying, so a test that pushes right after the client sees the reply can't miss it.
            let keep = lock.withLock {
                if stopped { return false }
                held.append(connection)
                return true
            }
            guard keep else {
                close(connection)
                return
            }
            lock.withLock {
                try? UnixSocket.writeAll(fd: connection, data: Data((text + "\n").utf8))
            }
        case .close:
            close(connection)
        }
    }
}

/// JSON lines shaped like herdr's replies and events.
enum FakeHerdr {
    static func agentList(id: String, _ agents: [(pane: String, status: String)]) -> String {
        let items = agents.map { agent in
            #"{"agent":"claude","agent_status":"\#(agent.status)","focused":false,"pane_id":"\#(agent.pane)","tab_id":"w1:t1","workspace_id":"w1","terminal_id":"term_\#(agent.pane)","revision":1,"terminal_title_stripped":"Task in \#(agent.pane)"}"#
        }
        return #"{"id":"\#(id)","result":{"type":"agent_list","agents":[\#(items.joined(separator: ","))]}}"#
    }

    static func subscriptionStarted(id: String) -> String {
        #"{"id":"\#(id)","result":{"type":"subscription_started"}}"#
    }

    static func event(_ kind: String, pane: String) -> String {
        #"{"event":"\#(kind)","data":{"pane_id":"\#(pane)","workspace_id":"w1"}}"#
    }

    static func error(id: String, code: String, message: String) -> String {
        #"{"id":"\#(id)","error":{"code":"\#(code)","message":"\#(message)"}}"#
    }
}
