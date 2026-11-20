import CryptoKit
import Darwin
import Foundation

/// One WebSocket frame (RFC 6455, section 5.2).
struct WebSocketFrame: Equatable, Sendable {
    enum Opcode: UInt8, Sendable {
        case continuation = 0x0
        case text = 0x1
        case binary = 0x2
        case close = 0x8
        case ping = 0x9
        case pong = 0xA
    }

    /// Frames larger than this are refused. rex sends at most 1 MiB per message.
    static let maxPayloadLength = 16 * 1024 * 1024

    var fin = true
    var opcode: Opcode
    var payload: [UInt8]

    /// The frame's bytes. A client must mask what it sends with a fresh `maskKey` of 4 bytes; a server must not mask.
    func encoded(maskKey: [UInt8]? = nil) -> [UInt8] {
        var bytes: [UInt8] = [(fin ? 0x80 : 0) | opcode.rawValue]
        let maskBit: UInt8 = maskKey == nil ? 0 : 0x80
        switch payload.count {
        case ..<126:
            bytes.append(maskBit | UInt8(payload.count))
        case ...0xFFFF:
            bytes.append(maskBit | 126)
            bytes += withUnsafeBytes(of: UInt16(payload.count).bigEndian, Array.init)
        default:
            bytes.append(maskBit | 127)
            bytes += withUnsafeBytes(of: UInt64(payload.count).bigEndian, Array.init)
        }
        if let maskKey {
            bytes += maskKey
            bytes += payload.enumerated().map { $0.element ^ maskKey[$0.offset % 4] }
        } else {
            bytes += payload
        }
        return bytes
    }

    /// Decodes the frame at the start of `bytes`, unmasking it if it's masked. Returns nil when `bytes` doesn't
    /// hold the whole frame yet, and the frame's length in bytes otherwise.
    static func decode(_ bytes: ArraySlice<UInt8>) throws -> (frame: WebSocketFrame, length: Int)? {
        guard bytes.count >= 2 else { return nil }
        let start = bytes.startIndex
        let first = bytes[start], second = bytes[start + 1]
        guard first & 0x70 == 0 else { throw HerdrError.invalidResponse("WebSocket frame uses an extension") }
        guard let opcode = Opcode(rawValue: first & 0x0F) else {
            throw HerdrError.invalidResponse("unknown WebSocket opcode \(first & 0x0F)")
        }

        var header = 2
        var length = Int(second & 0x7F)
        if length == 126 {
            guard bytes.count >= 4 else { return nil }
            length = bytes[(start + 2)..<(start + 4)].reduce(0) { $0 << 8 | Int($1) }
            header = 4
        } else if length == 127 {
            guard bytes.count >= 10 else { return nil }
            let long = bytes[(start + 2)..<(start + 10)].reduce(UInt64(0)) { $0 << 8 | UInt64($1) }
            guard long <= UInt64(maxPayloadLength) else { throw HerdrError.invalidResponse("WebSocket frame too large") }
            length = Int(long)
            header = 10
        }
        guard length <= maxPayloadLength else { throw HerdrError.invalidResponse("WebSocket frame too large") }

        let masked = second & 0x80 != 0
        let maskKey: [UInt8]?
        if masked {
            guard bytes.count >= header + 4 else { return nil }
            maskKey = Array(bytes[(start + header)..<(start + header + 4)])
            header += 4
        } else {
            maskKey = nil
        }
        guard bytes.count >= header + length else { return nil }

        var payload = Array(bytes[(start + header)..<(start + header + length)])
        if let maskKey {
            for index in payload.indices { payload[index] ^= maskKey[index % 4] }
        }
        return (WebSocketFrame(fin: first & 0x80 != 0, opcode: opcode, payload: payload), header + length)
    }
}

/// A WebSocket client connection on a Unix socket, for rex's control connection.
///
/// Apple's WebSocket clients can't open a Unix socket, hence this one. It's deliberately small: text messages
/// only, which is all rex sends, and no extensions, so no compression. Its calls block: make them off the main
/// thread. One thread reads with `receive()`; any thread may send.
final class WebSocketConnection: @unchecked Sendable {
    private let lock = NSLock()
    /// -1 once closed. Guarded by `lock`, so a closed descriptor number is never written to or shut down after reuse.
    private var fd: Int32
    /// Bytes read but not decoded yet. Only the reading thread touches it.
    private var buffer: [UInt8] = []
    private var chunk = [UInt8](repeating: 0, count: 64 * 1024)

    private init(fd: Int32) {
        self.fd = fd
    }

    /// Connects to the server at `socketPath` and upgrades `GET path` to a WebSocket that speaks `subprotocol`.
    /// `timeout` applies to the handshake and to every later send. Throws `HerdrError.notRunning` when nothing
    /// listens on the socket.
    static func connect(socketPath: String, path: String, subprotocol: String, timeout: TimeInterval) throws -> WebSocketConnection {
        let fd = try UnixSocket.connect(path: socketPath, timeout: timeout)
        let connection = WebSocketConnection(fd: fd)
        do {
            let key = Data((0..<16).map { _ in UInt8.random(in: 0...255) }).base64EncodedString()
            try UnixSocket.writeAll(fd: fd, data: handshakeRequest(path: path, key: key, subprotocol: subprotocol))
            try validateHandshake(response: connection.readHandshakeResponse(), key: key, subprotocol: subprotocol)
            return connection
        } catch {
            connection.close()
            throw error
        }
    }

    static func handshakeRequest(path: String, key: String, subprotocol: String) -> Data {
        // Over a Unix socket any host name works.
        let lines = [
            "GET \(path) HTTP/1.1",
            "Host: localhost",
            "Upgrade: websocket",
            "Connection: Upgrade",
            "Sec-WebSocket-Key: \(key)",
            "Sec-WebSocket-Version: 13",
            "Sec-WebSocket-Protocol: \(subprotocol)",
        ]
        return Data((lines.joined(separator: "\r\n") + "\r\n\r\n").utf8)
    }

    /// The `Sec-WebSocket-Accept` value a server must answer `key` with.
    static func acceptValue(for key: String) -> String {
        let digest = Insecure.SHA1.hash(data: Data((key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").utf8))
        return Data(digest).base64EncodedString()
    }

    /// Checks the server's answer to the upgrade request: status 101, the accept value for `key`, and the subprotocol.
    /// Header names are compared case-insensitively: rex writes `Sec-Websocket-Accept`.
    static func validateHandshake(response: String, key: String, subprotocol: String) throws {
        let lines = response.components(separatedBy: "\r\n")
        let status = lines.first ?? ""
        guard status.hasPrefix("HTTP/1.1 101") else {
            throw HerdrError.invalidResponse("WebSocket upgrade refused: \(status)")
        }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            headers[name] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        guard headers["sec-websocket-accept"] == acceptValue(for: key) else {
            throw HerdrError.invalidResponse("WebSocket upgrade has a wrong Sec-WebSocket-Accept")
        }
        guard headers["sec-websocket-protocol"] == subprotocol else {
            throw HerdrError.invalidResponse("WebSocket upgrade didn't agree to \(subprotocol)")
        }
    }

    /// Stops timing out reads. Messages can be minutes apart, so call it once the connection is set up.
    func waitForeverOnReceive() {
        lock.withLock {
            guard fd >= 0 else { return }
            var forever = timeval(tv_sec: 0, tv_usec: 0)
            setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &forever, socklen_t(MemoryLayout<timeval>.size))
        }
    }

    func send(text: String) throws {
        try send(WebSocketFrame(opcode: .text, payload: Array(text.utf8)))
    }

    /// Returns the next text message, or nil once the server has closed the connection. Answers pings and
    /// joins fragmented messages on the way.
    func receive() throws -> String? {
        var message: [UInt8] = []
        var inMessage = false
        while true {
            guard let frame = try nextFrame() else { return nil }
            switch frame.opcode {
            case .ping:
                try send(WebSocketFrame(opcode: .pong, payload: frame.payload))
            case .pong:
                continue
            case .close:
                // Echo the close, as the protocol asks. The server closes the socket after it.
                try? send(WebSocketFrame(opcode: .close, payload: Array(frame.payload.prefix(2))))
                return nil
            case .text, .binary:
                guard !inMessage else { throw HerdrError.invalidResponse("WebSocket message started inside another") }
                message = frame.payload
                inMessage = true
            case .continuation:
                guard inMessage else { throw HerdrError.invalidResponse("WebSocket continuation without a message") }
                message += frame.payload
                guard message.count <= WebSocketFrame.maxPayloadLength else {
                    throw HerdrError.invalidResponse("WebSocket message too large")
                }
            }
            if inMessage && frame.fin {
                return String(decoding: message, as: UTF8.self)
            }
        }
    }

    /// Sends a close frame, then shuts the socket down, which also wakes a thread blocked in `receive()`.
    /// Call `close()` afterwards from the reading thread, or when nothing reads.
    func shutDown() {
        try? send(WebSocketFrame(opcode: .close, payload: withUnsafeBytes(of: UInt16(1000).bigEndian, Array.init)))
        lock.withLock {
            if fd >= 0 { _ = Darwin.shutdown(fd, SHUT_RDWR) }
        }
    }

    func close() {
        lock.withLock {
            if fd >= 0 {
                Darwin.close(fd)
                fd = -1
            }
        }
    }

    private func send(_ frame: WebSocketFrame) throws {
        let bytes = frame.encoded(maskKey: (0..<4).map { _ in UInt8.random(in: 0...255) })
        try lock.withLock {
            guard fd >= 0 else { throw HerdrError.connectionClosed }
            try UnixSocket.writeAll(fd: fd, data: Data(bytes))
        }
    }

    private func nextFrame() throws -> WebSocketFrame? {
        while true {
            if let (frame, length) = try WebSocketFrame.decode(buffer[...]) {
                buffer.removeFirst(length)
                return frame
            }
            guard try fill() else { return nil }
        }
    }

    /// Reads the HTTP response to the upgrade request, up to and without its blank line.
    /// Whatever arrives after it stays in `buffer` for the first frame.
    private func readHandshakeResponse() throws -> String {
        let end: [UInt8] = Array("\r\n\r\n".utf8)
        while true {
            if let range = buffer.firstRange(of: end) {
                let response = String(decoding: buffer[..<range.lowerBound], as: UTF8.self)
                buffer.removeFirst(range.upperBound)
                return response
            }
            guard buffer.count < 64 * 1024 else { throw HerdrError.invalidResponse("WebSocket upgrade response too long") }
            guard try fill() else { throw HerdrError.connectionClosed }
        }
    }

    /// Reads what's available into `buffer`. Returns false once the server has closed the connection.
    private func fill() throws -> Bool {
        let fd = lock.withLock { self.fd }
        guard fd >= 0 else { return false }
        while true {
            let count = read(fd, &chunk, chunk.count)
            if count < 0 {
                if errno == EINTR { continue }
                if errno == EAGAIN { throw HerdrError.timedOut }
                // A socket shut down by `shutDown()` can report an error instead of the end of the stream.
                if errno == ECONNRESET || errno == ENOTCONN { return false }
                throw HerdrError.io(errno: errno)
            }
            if count == 0 { return false }
            buffer += chunk[..<count]
            return true
        }
    }
}
