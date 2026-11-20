import Darwin
import Foundation
@testable import HerdrMenubar

/// A stand-in rex server on a temporary Unix socket, so tests never touch the user's real one.
/// It speaks rex's control protocol: a WebSocket upgrade, a hello and a welcome, then requests that `handler`
/// answers, and events that tests push.
final class FakeRexServer: @unchecked Sendable {
    enum Reply {
        /// Answer with this JSON as the response's payload.
        case result(String)
        case error(code: String, message: String)
        /// Don't answer at all.
        case none
    }

    static let welcome = #"{"type":"welcome","protocol":"rex.control.v1","limits":{"max_message_bytes":1048576},"api_revision":18}"#

    let path: String
    private let handler: @Sendable (_ method: String, _ payload: [String: Any]) -> Reply
    private let welcome: String
    private let lock = NSLock()
    private var receivedRequests: [(method: String, payload: [String: Any])] = []
    private var receivedHellos: [[String: Any]] = []
    private var receivedPongs: [[UInt8]] = []
    private var open: [Connection] = []
    private var seq = 0
    private var stopped = false
    private let listener: Int32
    private let acceptLoopDone = DispatchSemaphore(value: 0)

    /// One client connection. Its lock keeps frames written from different threads whole.
    private final class Connection: @unchecked Sendable {
        let fd: Int32
        let lock = NSLock()

        init(fd: Int32) {
            self.fd = fd
        }

        func write(_ frame: WebSocketFrame) {
            lock.withLock { try? UnixSocket.writeAll(fd: fd, data: Data(frame.encoded())) }
        }
    }

    init(
        path: String = FakeHerdrServer.temporarySocketPath(),
        welcome: String = FakeRexServer.welcome,
        handler: @escaping @Sendable (_ method: String, _ payload: [String: Any]) -> Reply
    ) throws {
        self.path = path
        self.welcome = welcome
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
                let fd = accept(listener, nil, nil)
                if lock.withLock({ stopped }) {
                    if fd >= 0 { close(fd) }
                    return
                }
                guard fd >= 0 else {
                    if errno == EINTR { continue }
                    return
                }
                Thread.detachNewThread { self.serve(fd) }
            }
        }
    }

    /// The payloads of the requests for `method`, oldest first.
    func requests(method: String) -> [[String: Any]] {
        lock.withLock { receivedRequests.filter { $0.method == method }.map(\.payload) }
    }

    var requestCount: Int {
        lock.withLock { receivedRequests.count }
    }

    var hellos: [[String: Any]] {
        lock.withLock { receivedHellos }
    }

    var pongs: [[UInt8]] {
        lock.withLock { receivedPongs }
    }

    /// Connections that got their welcome and are still open.
    var connectionCount: Int {
        lock.withLock { open.count }
    }

    /// Sends `event`, the JSON of an event message's payload, to every open connection.
    func push(_ event: String) {
        lock.withLock {
            for connection in open {
                seq += 1
                let message = #"{"type":"event","seq":\#(seq),"payload":\#(event)}"#
                connection.write(WebSocketFrame(opcode: .text, payload: Array(message.utf8)))
            }
        }
    }

    func ping(_ payload: [UInt8]) {
        lock.withLock {
            for connection in open { connection.write(WebSocketFrame(opcode: .ping, payload: payload)) }
        }
    }

    /// Closes every connection without a close frame, like a server that stopped.
    func dropConnections() {
        lock.withLock {
            for connection in open { Darwin.shutdown(connection.fd, SHUT_RDWR) }
            open.removeAll()
        }
    }

    func stop() {
        lock.withLock { stopped = true }
        // Closing the listener doesn't wake a thread blocked in accept() on macOS, so connect once to wake it.
        if let fd = try? UnixSocket.connect(path: path, timeout: 1) { close(fd) }
        _ = acceptLoopDone.wait(timeout: .now() + 2)
        close(listener)
        dropConnections()
        unlink(path)
    }

    private func serve(_ fd: Int32) {
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        let connection = Connection(fd: fd)
        var buffer: [UInt8] = []
        defer {
            lock.withLock { open.removeAll { $0 === connection } }
            close(fd)
        }

        // The upgrade request.
        let end = Array("\r\n\r\n".utf8)
        while buffer.firstRange(of: end) == nil {
            guard read(fd, into: &buffer) else { return }
        }
        let headerEnd = buffer.firstRange(of: end)!
        let request = String(decoding: buffer[..<headerEnd.lowerBound], as: UTF8.self)
        buffer.removeFirst(headerEnd.upperBound)
        let key = request.components(separatedBy: "\r\n")
            .first { $0.lowercased().hasPrefix("sec-websocket-key:") }?
            .split(separator: ":", maxSplits: 1).last?
            .trimmingCharacters(in: .whitespaces) ?? ""
        // Header names written the way rex writes them.
        let response = [
            "HTTP/1.1 101 Switching Protocols",
            "Connection: Upgrade",
            "Sec-Websocket-Accept: \(WebSocketConnection.acceptValue(for: key))",
            "Sec-Websocket-Protocol: rex.control.v1",
            "Upgrade: websocket",
        ].joined(separator: "\r\n") + "\r\n\r\n"
        connection.lock.withLock { try? UnixSocket.writeAll(fd: fd, data: Data(response.utf8)) }

        var welcomed = false
        while true {
            guard let frame = nextFrame(fd, &buffer) else { return }
            switch frame.opcode {
            case .ping:
                connection.write(WebSocketFrame(opcode: .pong, payload: frame.payload))
            case .pong:
                lock.withLock { receivedPongs.append(frame.payload) }
            case .close:
                connection.write(WebSocketFrame(opcode: .close, payload: frame.payload))
                return
            case .text, .binary, .continuation:
                guard let message = try? JSONSerialization.jsonObject(with: Data(frame.payload)) as? [String: Any] else { return }
                if !welcomed {
                    lock.withLock { receivedHellos.append(message) }
                    let keep = lock.withLock {
                        if stopped { return false }
                        open.append(connection)
                        return true
                    }
                    guard keep else { return }
                    connection.write(WebSocketFrame(opcode: .text, payload: Array(welcome.utf8)))
                    welcomed = true
                    continue
                }
                answer(message, on: connection)
            }
        }
    }

    private func answer(_ message: [String: Any], on connection: Connection) {
        guard let id = message["id"] as? String, let method = message["method"] as? String else { return }
        let payload = message["payload"] as? [String: Any] ?? [:]
        lock.withLock { receivedRequests.append((method, payload)) }
        let response: String
        switch handler(method, payload) {
        case .result(let json):
            response = #"{"type":"response","id":"\#(id)","seq":0,"payload":\#(json)}"#
        case .error(let code, let text):
            response = #"{"type":"response","id":"\#(id)","seq":0,"error":{"code":"\#(code)","message":"\#(text)","status":400}}"#
        case .none:
            return
        }
        connection.write(WebSocketFrame(opcode: .text, payload: Array(response.utf8)))
    }

    private func nextFrame(_ fd: Int32, _ buffer: inout [UInt8]) -> WebSocketFrame? {
        while true {
            if let decoded = try? WebSocketFrame.decode(buffer[...]) {
                buffer.removeFirst(decoded.length)
                return decoded.frame
            }
            guard read(fd, into: &buffer) else { return nil }
        }
    }

    private func read(_ fd: Int32, into buffer: inout [UInt8]) -> Bool {
        var chunk = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let count = Darwin.read(fd, &chunk, chunk.count)
            if count < 0 && errno == EINTR { continue }
            guard count > 0 else { return false }
            buffer += chunk[..<count]
            return true
        }
    }
}

/// JSON shaped like rex's payloads.
enum FakeRex {
    /// A terminal's `program_status_changed` event, as an event message's payload.
    static func blockEvent(_ name: String, session: String = "session:1", block: String = "block:1") -> String {
        #"{"type":"session_event","payload":{"session_id":"\#(session)","event":{"type":"block_event","payload":{"block_id":"\#(block)","creator_name":"com.superlogical.terminal","name":"\#(name)","payload":{}}}}}"#
    }

    static func sessionEvent(_ type: String, session: String = "session:1", block: String = "block:1") -> String {
        #"{"type":"session_event","payload":{"session_id":"\#(session)","event":{"type":"\#(type)","payload":{"block_id":"\#(block)"}}}}"#
    }

    static func serverEvent(_ type: String) -> String {
        #"{"type":"\#(type)","payload":{"client_id":"client:9"}}"#
    }

    /// One record of a terminal's `program_status`.
    static func record(_ state: String, id: String? = nil, app: String = "claude-code", msg: String? = nil, owner: (pid: Int32, name: String)? = (100, "claude")) -> String {
        var fields = [#""state":"\#(state)""#, #""app":"\#(app)""#, #""effective_app":"\#(app)""#, #""updated_at":"2026-11-20T12:00:00Z""#]
        if let id { fields.append(#""id":"\#(id)""#) }
        if let msg { fields.append(#""msg":"\#(msg)""#) }
        if let owner { fields.append(#""owner":{"pid":\#(owner.pid),"name":"\#(owner.name)"}"#) }
        return "{" + fields.joined(separator: ",") + "}"
    }
}

/// A fake rex whose terminals the test can change. Each terminal answers `program_status`, `process` and `title`.
final class FakeRexWithTerminals: @unchecked Sendable {
    struct Terminal {
        var session = "session:1"
        var block: String
        var window: String? = "window:1"
        /// JSON records, such as from `FakeRex.record`.
        var records: [String] = []
        var foreground: (pid: Int32, name: String, cwd: String)? = (100, "claude", "/Users/me/dev/project")
        var title: String? = "Task"
    }

    private let lock = NSLock()
    private var current: [Terminal]
    private var apps: [String] = []
    private var performReply: FakeRexServer.Reply = .result("{}")
    private(set) var server: FakeRexServer!

    var terminals: [Terminal] {
        get { lock.withLock { current } }
        set { lock.withLock { current = newValue } }
    }

    /// `client.list` entries, such as from `FakeRexWithTerminals.app(…)`.
    var appClients: [String] {
        get { lock.withLock { apps } }
        set { lock.withLock { apps = newValue } }
    }

    /// The answer to `client.perform`.
    var performs: FakeRexServer.Reply {
        get { lock.withLock { performReply } }
        set { lock.withLock { performReply = newValue } }
    }

    static func app(_ id: String, platform: String = "macos", transport: String = "unix") -> String {
        #"{"client_id":"\#(id)","info":{"kind":"app","platform":"\#(platform)","name":"Rex"},"principal":{"kind":"peer","transport":"\#(transport)"}}"#
    }

    init(_ terminals: [Terminal], path: String = FakeHerdrServer.temporarySocketPath()) throws {
        current = terminals
        server = try FakeRexServer(path: path) { [unowned self] method, payload in
            self.answer(method, payload)
        }
    }

    private func answer(_ method: String, _ payload: [String: Any]) -> FakeRexServer.Reply {
        let terminals = self.terminals
        var sessions: [String] = []
        for terminal in terminals where !sessions.contains(terminal.session) { sessions.append(terminal.session) }
        let sessionList = sessions.map { #"{"session_id":"\#($0)","label":"work"}"# }.joined(separator: ",")

        switch method {
        case "session.attach_all", "session.list":
            return .result(#"{"sessions":[\#(sessionList)]}"#)
        case "session.list_blocks":
            let session = payload["session_id"] as? String
            let blocks = terminals.filter { $0.session == session }.map { terminal in
                let window = terminal.window.map { #","window_id":"\#($0)""# } ?? ""
                return #"{"block_id":"\#(terminal.block)","label":"shell","creator_name":"com.superlogical.terminal","placement":"placed"\#(window)}"#
            }
            return .result(#"{"blocks":[\#(blocks.joined(separator: ","))]}"#)
        case "block.method":
            guard let terminal = terminals.first(where: { $0.block == payload["block_id"] as? String }) else {
                return .error(code: "not_found", message: "block not found")
            }
            switch payload["method"] as? String {
            case "program_status":
                return .result(#"{"records":[\#(terminal.records.joined(separator: ","))]}"#)
            case "process":
                guard let foreground = terminal.foreground else { return .result(#"{"last_exit":null}"#) }
                return .result(#"{"last_exit":null,"foreground":{"pid":\#(foreground.pid),"name":"\#(foreground.name)","cwd":"\#(foreground.cwd)"}}"#)
            case "title":
                return .result(terminal.title.map { #"{"title":"\#($0)"}"# } ?? "{}")
            default:
                return .error(code: "method_not_found", message: "not faked")
            }
        case "session.focus_block":
            guard terminals.contains(where: { $0.block == payload["block_id"] as? String }) else {
                return .error(code: "not_found", message: "block not found")
            }
            return .result(#"{"revision":2}"#)
        case "client.list":
            return .result(#"{"clients":[\#(appClients.joined(separator: ","))]}"#)
        case "client.perform":
            return performs
        default:
            return .error(code: "method_not_found", message: "not faked")
        }
    }
}
