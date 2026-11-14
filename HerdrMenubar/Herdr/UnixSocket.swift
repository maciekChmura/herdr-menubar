import Darwin
import Foundation

/// Blocking POSIX helpers for herdr's Unix socket. Call them off the main thread.
enum UnixSocket {
    /// Connects to `path`, writes `request`, and returns the first line of the reply (without the newline).
    static func roundTrip(path: String, request: Data, timeout: TimeInterval) throws -> Data {
        let fd = try connect(path: path, timeout: timeout)
        defer { close(fd) }
        try writeAll(fd: fd, data: request)
        return try readLine(fd: fd)
    }

    /// Opens a stream socket connected to `path`, with `timeout` applied to reads and writes.
    /// Throws `HerdrError.notRunning` when the socket file is missing or nothing accepts connections on it.
    static func connect(path: String, timeout: TimeInterval) throws -> Int32 {
        var addr = try address(path)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw HerdrError.io(errno: errno) }

        setTimeouts(fd: fd, timeout)
        // Without this, writing to a socket the server already closed kills the app with SIGPIPE.
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))

        let result = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        if result != 0 {
            let error = errno
            close(fd)
            if error == ENOENT || error == ECONNREFUSED { throw HerdrError.notRunning }
            throw HerdrError.io(errno: error)
        }
        return fd
    }

    /// Sets the read and write timeouts. Zero means wait forever.
    static func setTimeouts(fd: Int32, _ timeout: TimeInterval) {
        var tv = timeval(
            tv_sec: Int(timeout),
            tv_usec: Int32((timeout - timeout.rounded(.down)) * 1_000_000)
        )
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
    }

    /// Builds a `sockaddr_un` for `path`.
    static func address(_ path: String) throws -> sockaddr_un {
        var addr = sockaddr_un()
        let bytes = Array(path.utf8)
        // sun_path also needs room for the terminating NUL.
        guard bytes.count < MemoryLayout.size(ofValue: addr.sun_path) else {
            throw HerdrError.socketPathTooLong
        }
        addr.sun_family = sa_family_t(AF_UNIX)
        addr.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        withUnsafeMutableBytes(of: &addr.sun_path) { $0.copyBytes(from: bytes) }
        return addr
    }

    static func writeAll(fd: Int32, data: Data) throws {
        try data.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                let written = write(fd, buffer.baseAddress! + offset, buffer.count - offset)
                if written < 0 {
                    if errno == EINTR { continue }
                    if errno == EAGAIN { throw HerdrError.timedOut }
                    throw HerdrError.io(errno: errno)
                }
                offset += written
            }
        }
    }

    /// Reads one line. Throws `connectionClosed` if the peer closes the connection before sending anything.
    static func readLine(fd: Int32) throws -> Data {
        guard let line = try LineReader(fd: fd).next() else { throw HerdrError.connectionClosed }
        return line
    }
}

/// Splits a socket's byte stream into newline-terminated lines.
/// Bytes that arrive after the current line are kept for the next call, so no line is lost.
final class LineReader {
    private let fd: Int32
    private var buffer = Data()
    private var chunk = [UInt8](repeating: 0, count: 64 * 1024)

    init(fd: Int32) {
        self.fd = fd
    }

    /// Returns the next line without its newline, or nil once the peer has closed the connection.
    /// A last line that has no newline is returned as it is.
    func next() throws -> Data? {
        while true {
            if let newline = buffer.firstIndex(of: UInt8(ascii: "\n")) {
                let line = Data(buffer[buffer.startIndex..<newline])
                buffer.removeSubrange(buffer.startIndex...newline)
                return line
            }
            let count = read(fd, &chunk, chunk.count)
            if count < 0 {
                if errno == EINTR { continue }
                if errno == EAGAIN { throw HerdrError.timedOut }
                throw HerdrError.io(errno: errno)
            }
            if count == 0 {
                if buffer.isEmpty { return nil }
                defer { buffer.removeAll() }
                return buffer
            }
            buffer.append(contentsOf: chunk[..<count])
        }
    }
}
