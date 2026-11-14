import Darwin
import Foundation

enum HerdrError: Error, Equatable {
    /// No herdr server is listening: the socket file is missing, or nothing accepts connections on it.
    case notRunning
    /// herdr answered with an error response.
    case server(code: String, message: String)
    case timedOut
    /// herdr closed the connection without replying, or closed a subscription.
    case connectionClosed
    case socketPathTooLong
    case io(errno: Int32)
    case invalidResponse(String)
}

/// One entry in an `events.subscribe` request, such as `{"type": "pane.agent_status_changed", "pane_id": "w1:p1"}`.
struct Subscription: Encodable, Equatable, Sendable {
    let type: String
    var paneId: String?
}

/// Talks to the herdr server over its Unix socket.
///
/// herdr closes the connection after replying to an ordinary request, so every request opens a fresh one.
/// A subscription keeps its own connection open. See `docs/herdr/README.md`.
struct HerdrClient: Sendable {
    let socketPath: String
    var timeout: TimeInterval = 5

    func listAgents() async throws -> [Agent] {
        let result: AgentListResult = try await request("agent.list")
        return result.agents
    }

    /// Focuses an agent in herdr, which also marks a `done` agent as seen.
    /// `target` can be a pane ID or an agent name.
    func focusAgent(_ target: String) async throws {
        let _: IgnoredResult = try await request("agent.focus", params: AgentTarget(target: target))
    }

    func request<Result: Decodable>(_ method: String) async throws -> Result {
        try await request(method, params: EmptyParams())
    }

    func request<Params: Encodable, Result: Decodable>(_ method: String, params: Params) async throws -> Result {
        let id = UUID().uuidString
        let line = try Self.encodeRequest(id: id, method: method, params: params)
        let socketPath = socketPath
        let timeout = timeout
        let reply = try await Self.runBlocking {
            try UnixSocket.roundTrip(path: socketPath, request: line, timeout: timeout)
        }
        return try Self.decodeResponse(Result.self, from: reply, requestID: id)
    }

    /// Subscribes to herdr events. Returns once herdr has confirmed the subscription.
    ///
    /// The stream yields each event's kind, such as "pane.agent_status_changed". It ends by throwing
    /// `connectionClosed` when herdr closes the connection, and it closes the connection when the consumer
    /// stops iterating.
    func subscribe(_ subscriptions: [Subscription]) async throws -> AsyncThrowingStream<String, any Error> {
        let id = UUID().uuidString
        let line = try Self.encodeRequest(id: id, method: "events.subscribe", params: SubscribeParams(subscriptions: subscriptions))
        let socketPath = socketPath
        let timeout = timeout
        let connection = try await Self.runBlocking {
            let fd = try UnixSocket.connect(path: socketPath, timeout: timeout)
            do {
                try UnixSocket.writeAll(fd: fd, data: line)
                let reader = LineReader(fd: fd)
                guard let ack = try reader.next() else { throw HerdrError.connectionClosed }
                let started = try HerdrClient.decodeResponse(SubscriptionStarted.self, from: ack, requestID: id)
                guard started.type == "subscription_started" else {
                    throw HerdrError.invalidResponse("unexpected subscription reply type \(started.type)")
                }
                // Events can be minutes apart, so stop timing out reads.
                UnixSocket.setTimeouts(fd: fd, 0)
                return SubscriptionConnection(fd: fd, reader: reader)
            } catch {
                close(fd)
                throw error
            }
        }
        return connection.events()
    }

    static func encodeRequest<Params: Encodable>(id: String, method: String, params: Params) throws -> Data {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        var line = try encoder.encode(RequestEnvelope(id: id, method: method, params: params))
        line.append(UInt8(ascii: "\n"))
        return line
    }

    /// Decodes one response line. Pass `requestID: nil` to skip checking that the reply's id matches.
    static func decodeResponse<Result: Decodable>(
        _ type: Result.Type,
        from data: Data,
        requestID: String?
    ) throws -> Result {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase

        let envelope: ResponseEnvelope<Result>
        do {
            envelope = try decoder.decode(ResponseEnvelope<Result>.self, from: data)
        } catch {
            throw HerdrError.invalidResponse(String(describing: error))
        }
        if let requestID, envelope.id != requestID {
            throw HerdrError.invalidResponse("reply id \(envelope.id ?? "nil") doesn't match request id \(requestID)")
        }
        if let error = envelope.error {
            throw HerdrError.server(code: error.code, message: error.message)
        }
        guard let result = envelope.result else {
            throw HerdrError.invalidResponse("reply has neither result nor error")
        }
        return result
    }

    /// Where the herdr socket is, in order of precedence:
    /// 1. the `HerdrSocketPath` user default, which can also be set at launch with `-HerdrSocketPath <path>`;
    /// 2. herdr's own `HERDR_SOCKET_PATH` environment variable;
    /// 3. herdr's default, `~/.config/herdr/herdr.sock`.
    static func resolveSocketPath(
        defaults: UserDefaults = .standard,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> String {
        if let path = defaults.string(forKey: "HerdrSocketPath"), !path.isEmpty { return path }
        if let path = environment["HERDR_SOCKET_PATH"], !path.isEmpty { return path }
        return home.appending(path: ".config/herdr/herdr.sock").path(percentEncoded: false)
    }

    /// Runs blocking socket work on a background queue.
    private static func runBlocking<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(with: Result { try work() })
            }
        }
    }
}

/// The open connection of one subscription. A dedicated thread reads its events.
private final class SubscriptionConnection: @unchecked Sendable {
    private let lock = NSLock()
    /// -1 once closed. Guarded by `lock`, so a closed descriptor number is never shut down after reuse.
    private var fd: Int32
    private let reader: LineReader

    init(fd: Int32, reader: LineReader) {
        self.fd = fd
        self.reader = reader
    }

    func events() -> AsyncThrowingStream<String, any Error> {
        AsyncThrowingStream { continuation in
            // Shutting the socket down wakes the reader thread, which then closes it.
            continuation.onTermination = { _ in self.shutDown() }
            Thread.detachNewThread {
                do {
                    while let line = try self.reader.next() {
                        continuation.yield(Self.eventKind(of: line))
                    }
                    continuation.finish(throwing: HerdrError.connectionClosed)
                } catch {
                    continuation.finish(throwing: error)
                }
                self.close()
            }
        }
    }

    private func shutDown() {
        lock.withLock {
            if fd >= 0 { _ = Darwin.shutdown(fd, SHUT_RDWR) }
        }
    }

    private func close() {
        lock.withLock {
            if fd >= 0 {
                Darwin.close(fd)
                fd = -1
            }
        }
    }

    private static func eventKind(of line: Data) -> String {
        struct Envelope: Decodable { let event: String }
        return (try? JSONDecoder().decode(Envelope.self, from: line).event) ?? "unrecognized"
    }
}

struct EmptyParams: Encodable {}

private struct AgentTarget: Encodable {
    let target: String
}

/// Accepts any `result`, for requests where only success or failure matters.
private struct IgnoredResult: Decodable {
    init(from decoder: any Decoder) throws {}
}

private struct SubscribeParams: Encodable {
    let subscriptions: [Subscription]
}

private struct SubscriptionStarted: Decodable {
    let type: String
}

private struct RequestEnvelope<Params: Encodable>: Encodable {
    let id: String
    let method: String
    let params: Params
}

private struct ResponseEnvelope<Result: Decodable>: Decodable {
    let id: String?
    let result: Result?
    let error: ErrorBody?
}

private struct ErrorBody: Decodable {
    let code: String
    let message: String
}
