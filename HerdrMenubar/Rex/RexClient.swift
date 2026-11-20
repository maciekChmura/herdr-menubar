import Foundation

/// Where the rex server is, and how to open its control connection. See `docs/rex/README.md`.
struct RexClient: Sendable {
    let socketPath: String
    var timeout: TimeInterval = 5

    /// The control API revision this app was written for. The server translates older and newer ones,
    /// but this app only knows these shapes, so it asks for exactly this one.
    static let apiRevision = 18
    static let subprotocol = "rex.control.v1"

    /// Opens the control connection and exchanges the hello and the welcome.
    func connect() async throws -> RexConnection {
        let socketPath = socketPath
        let timeout = timeout
        return try await runBlocking {
            let socket = try WebSocketConnection.connect(
                socketPath: socketPath, path: "/api/control", subprotocol: Self.subprotocol, timeout: timeout
            )
            do {
                try socket.send(text: Self.hello())
                guard let reply = try socket.receive() else { throw HerdrError.connectionClosed }
                try Self.checkWelcome(reply)
                socket.waitForeverOnReceive()
                return RexConnection(socket: socket, timeout: timeout)
            } catch {
                socket.close()
                throw error
            }
        }
    }

    static func hello() throws -> String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
        // Not "app": `rex do` and `rex -C` pick the app client on their own when only one is connected.
        let hello = Hello(
            apiRevision: apiRevision,
            apiMinRevision: apiRevision,
            client: .init(kind: "other", platform: "macos", name: "herdr-menubar", version: version)
        )
        return String(decoding: try RexConnection.encoder.encode(hello), as: UTF8.self)
    }

    static func checkWelcome(_ message: String) throws {
        struct Welcome: Decodable {
            let type: String
            let `protocol`: String?
        }
        let welcome: Welcome
        do {
            welcome = try RexConnection.decoder.decode(Welcome.self, from: Data(message.utf8))
        } catch {
            throw HerdrError.invalidResponse("rex's first message isn't a welcome: \(error)")
        }
        guard welcome.type == "welcome", welcome.protocol == subprotocol else {
            throw HerdrError.invalidResponse("rex's first message is \(welcome.type), not a welcome")
        }
    }

    /// Where the rex socket is: the `RexSocketPath` user default, which can also be set at launch with
    /// `-RexSocketPath <path>`, or else rex's default, `~/Library/Application Support/rex/server.sock`.
    static func resolveSocketPath(
        defaults: UserDefaults = .standard,
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> String {
        if let path = defaults.string(forKey: "RexSocketPath"), !path.isEmpty { return path }
        return home.appending(path: "Library/Application Support/rex/server.sock").path(percentEncoded: false)
    }

    private struct Hello: Encodable {
        struct Client: Encodable {
            let kind: String
            let platform: String
            let name: String
            let version: String
        }

        let type = "hello"
        let apiRevision: Int
        let apiMinRevision: Int
        let client: Client
    }
}

/// Something that happened in rex, such as a terminal reporting a new status.
struct RexEvent: Equatable, Sendable {
    /// A server event's type, such as "session_created"; a session event's type, such as "block_closed";
    /// or a block event's name, such as "program_status_changed".
    let name: String
    let sessionId: String?
    let blockId: String?
}

/// An open control connection to rex: one WebSocket that carries requests, their responses, and events.
///
/// A dedicated thread reads the connection. It hands each response to the request waiting for it and each
/// event to `events`. When the connection drops, every waiting request and `events` fail with
/// `HerdrError.connectionClosed`.
final class RexConnection: @unchecked Sendable {
    static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        return encoder
    }()

    static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return decoder
    }()

    let events: AsyncThrowingStream<RexEvent, any Error>
    private let eventsContinuation: AsyncThrowingStream<RexEvent, any Error>.Continuation
    private let socket: WebSocketConnection
    private let timeout: TimeInterval
    private let lock = NSLock()
    private var pending: [String: CheckedContinuation<Data, any Error>] = [:]
    private var nextId = 0
    /// Set once the connection is gone. Guarded by `lock`.
    private var closed = false

    fileprivate init(socket: WebSocketConnection, timeout: TimeInterval) {
        self.socket = socket
        self.timeout = timeout
        (events, eventsContinuation) = AsyncThrowingStream.makeStream()
        Thread.detachNewThread { self.readUntilClosed() }
    }

    /// Calls `method` and decodes its result. Throws `HerdrError.server` when rex answers with an error, and
    /// `HerdrError.timedOut` when it doesn't answer in time.
    func call<Payload: Encodable, Result: Decodable>(_ method: String, _ payload: Payload, as type: Result.Type) async throws -> Result {
        let reply = try await send(method, payload)
        return try Self.decodeResponse(Result.self, from: reply)
    }

    /// Calls `method` when only success or failure matters.
    func call<Payload: Encodable>(_ method: String, _ payload: Payload) async throws {
        _ = try await call(method, payload, as: Ignored.self)
    }

    /// Closes the connection. Requests still waiting fail, and `events` ends.
    func close() {
        socket.shutDown()
    }

    static func decodeResponse<Result: Decodable>(_ type: Result.Type, from data: Data) throws -> Result {
        let response: Response<Result>
        do {
            response = try decoder.decode(Response<Result>.self, from: data)
        } catch {
            throw HerdrError.invalidResponse(String(describing: error))
        }
        if let error = response.error {
            throw HerdrError.server(code: error.code, message: error.message)
        }
        // A method with an empty result may leave `payload` out.
        if let payload = response.payload { return payload }
        if let empty = try? decoder.decode(Result.self, from: Data("{}".utf8)) { return empty }
        throw HerdrError.invalidResponse("rex's response has neither payload nor error")
    }

    /// Reads the parts of an `event` message this app uses.
    static func decodeEvent(_ data: Data) -> RexEvent? {
        guard let message = try? decoder.decode(EventMessage.self, from: data) else { return nil }
        let outer = message.payload
        guard outer.type == "session_event", let inner = outer.payload?.event else {
            return RexEvent(name: outer.type, sessionId: outer.payload?.sessionId, blockId: nil)
        }
        if inner.type == "block_event", let name = inner.payload?.name {
            return RexEvent(name: name, sessionId: outer.payload?.sessionId, blockId: inner.payload?.blockId)
        }
        return RexEvent(name: inner.type, sessionId: outer.payload?.sessionId, blockId: inner.payload?.blockId)
    }

    private func send<Payload: Encodable>(_ method: String, _ payload: Payload) async throws -> Data {
        let (id, text): (String, String) = try lock.withLock {
            guard !closed else { throw HerdrError.connectionClosed }
            nextId += 1
            let id = String(nextId)
            let request = Request(id: id, method: method, payload: payload)
            return (id, String(decoding: try Self.encoder.encode(request), as: UTF8.self))
        }
        let socket = socket
        let timeout = timeout
        return try await withCheckedThrowingContinuation { continuation in
            let registered = lock.withLock {
                guard !closed else { return false }
                pending[id] = continuation
                return true
            }
            guard registered else {
                continuation.resume(throwing: HerdrError.connectionClosed)
                return
            }
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    try socket.send(text: text)
                } catch {
                    self.finish(id, with: .failure(error))
                }
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                self.finish(id, with: .failure(HerdrError.timedOut))
            }
        }
    }

    /// Resumes the request `id` if it's still waiting.
    private func finish(_ id: String, with result: Result<Data, any Error>) {
        let continuation = lock.withLock { pending.removeValue(forKey: id) }
        continuation?.resume(with: result)
    }

    private func readUntilClosed() {
        var failure: any Error = HerdrError.connectionClosed
        do {
            while let text = try socket.receive() {
                let data = Data(text.utf8)
                guard let header = try? Self.decoder.decode(Header.self, from: data) else { continue }
                switch header.type {
                case "response":
                    if let id = header.id { finish(id, with: .success(data)) }
                case "event":
                    if let event = Self.decodeEvent(data) { eventsContinuation.yield(event) }
                default:
                    // A newer server may send messages this app doesn't know.
                    continue
                }
            }
        } catch {
            failure = error
        }
        let waiting = lock.withLock {
            closed = true
            defer { pending.removeAll() }
            return Array(pending.values)
        }
        waiting.forEach { $0.resume(throwing: HerdrError.connectionClosed) }
        eventsContinuation.finish(throwing: failure)
        socket.close()
    }

    private struct Request<Payload: Encodable>: Encodable {
        let type = "request"
        let id: String
        let method: String
        let payload: Payload
    }

    private struct Header: Decodable {
        let type: String
        let id: String?
    }

    private struct Response<Result: Decodable>: Decodable {
        let payload: Result?
        let error: ErrorBody?
    }

    private struct ErrorBody: Decodable {
        let code: String
        let message: String
    }

    private struct Ignored: Decodable {
        init(from decoder: any Decoder) throws {}
    }

    /// `{"type":"event","payload":{"type":…,"payload":{"session_id":…,"event":{"type":…,"payload":{"block_id":…,"name":…}}}}}`
    private struct EventMessage: Decodable {
        struct Outer: Decodable {
            let type: String
            let payload: OuterPayload?
        }

        struct OuterPayload: Decodable {
            let sessionId: String?
            let event: Inner?
        }

        struct Inner: Decodable {
            let type: String
            let payload: InnerPayload?
        }

        struct InnerPayload: Decodable {
            let blockId: String?
            let name: String?
        }

        let payload: Outer
    }
}

// MARK: Methods

/// A session from `session.list`.
struct RexSession: Decodable, Equatable, Sendable {
    let sessionId: String
    let label: String
}

/// A block from `session.list_blocks`. Today every block is a terminal.
struct RexBlock: Decodable, Equatable, Sendable {
    let blockId: String?
    let label: String?
    let creatorName: String?
    /// The window the block is in, or nil when it's detached.
    let windowId: String?
}

/// One record from a terminal's `program_status`: what a program in it reported with OSC 7501.
struct RexStatusRecord: Decodable, Equatable, Sendable {
    /// Nil or empty for the root record.
    var id: String?
    /// "idle", "working", "done", "blocked" or "error".
    var state: String
    var kind: String?
    var effectiveApp: String?
    var msg: String?
    /// The terminal's foreground process when the report arrived, if rex could tell.
    var owner: RexProcess?
}

/// A process as rex identifies it. Compare the name as well as the pid, because pids are reused.
struct RexProcess: Decodable, Equatable, Sendable {
    let pid: Int32
    let name: String
    var cwd: String?
}

/// An app connected to rex, such as Rex.app, from `client.list`.
struct RexAppClient: Decodable, Equatable, Sendable {
    struct Info: Decodable, Equatable, Sendable {
        let kind: String?
        let platform: String?
    }

    struct Principal: Decodable, Equatable, Sendable {
        let kind: String?
        let transport: String?
    }

    let clientId: String
    let info: Info?
    let principal: Principal?

    /// A Mac app on this machine, connected over the local socket rather than from another device.
    var isLocalMacApp: Bool {
        info?.kind == "app" && info?.platform == "macos" && principal?.transport == "unix"
    }
}

extension RexConnection {
    /// Starts every event from the whole server. `all` is needed for the terminals' own events.
    func attachAll() async throws {
        struct Params: Encodable { let eventScope = "all" }
        try await call("session.attach_all", Params())
    }

    func sessions() async throws -> [RexSession] {
        struct Result: Decodable { let sessions: [RexSession]? }
        return try await call("session.list", EmptyParams(), as: Result.self).sessions ?? []
    }

    func blocks(inSession sessionId: String) async throws -> [RexBlock] {
        struct Result: Decodable { let blocks: [RexBlock]? }
        return try await call("session.list_blocks", SessionParams(sessionId: sessionId), as: Result.self).blocks ?? []
    }

    func programStatus(session: String, block: String) async throws -> [RexStatusRecord] {
        struct Result: Decodable { let records: [RexStatusRecord]? }
        return try await blockMethod("program_status", session: session, block: block, as: Result.self).records ?? []
    }

    /// The terminal's foreground process, or nil when it has none.
    func foregroundProcess(session: String, block: String) async throws -> RexProcess? {
        struct Result: Decodable { let foreground: RexProcess? }
        return try await blockMethod("process", session: session, block: block, as: Result.self).foreground
    }

    func title(session: String, block: String) async throws -> String? {
        struct Result: Decodable { let title: String? }
        return try await blockMethod("title", session: session, block: block, as: Result.self).title
    }

    func focusBlock(session: String, block: String) async throws {
        struct Params: Encodable {
            let sessionId: String
            let blockId: String
        }
        try await call("session.focus_block", Params(sessionId: session, blockId: block))
    }

    func appClients() async throws -> [RexAppClient] {
        struct Params: Encodable { let kinds = ["app"] }
        struct Result: Decodable { let clients: [RexAppClient]? }
        return try await call("client.list", Params(), as: Result.self).clients ?? []
    }

    /// Asks a connected app, such as Rex.app, to show a session. Fails with the code `refused` when the app's
    /// Remote Control setting is off.
    func selectSession(_ sessionId: String, inClient clientId: String) async throws {
        struct Params: Encodable {
            let clientId: String
            let action = "session.select"
            let args: SessionParams
            let timeoutMs = 3000
        }
        try await call("client.perform", Params(clientId: clientId, args: SessionParams(sessionId: sessionId)))
    }

    private func blockMethod<Result: Decodable>(_ method: String, session: String, block: String, as type: Result.Type) async throws -> Result {
        try await call("block.method", BlockMethodParams(sessionId: session, blockId: block, method: method), as: type)
    }
}

private struct SessionParams: Encodable {
    let sessionId: String
}

private struct BlockMethodParams: Encodable {
    let sessionId: String
    let blockId: String
    /// The block method's short name, such as "program_status".
    let method: String
    let args = EmptyParams()
}

/// Runs blocking socket work on a background queue.
func runBlocking<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
    try await withCheckedThrowingContinuation { continuation in
        DispatchQueue.global(qos: .userInitiated).async {
            continuation.resume(with: Result { try work() })
        }
    }
}
