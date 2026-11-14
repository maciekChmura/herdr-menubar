import Foundation

enum HerdrError: Error, Equatable {
    /// No herdr server is listening: the socket file is missing, or nothing accepts connections on it.
    case notRunning
    /// herdr answered with an error response.
    case server(code: String, message: String)
    case timedOut
    /// herdr closed the connection without replying.
    case connectionClosed
    case socketPathTooLong
    case io(errno: Int32)
    case invalidResponse(String)
}

/// Talks to the herdr server over its Unix socket.
///
/// herdr closes the connection after replying to an ordinary request, so every request opens a fresh one.
/// See `docs/herdr/README.md`.
struct HerdrClient: Sendable {
    let socketPath: String
    var timeout: TimeInterval = 5

    func listAgents() async throws -> [Agent] {
        let result: AgentListResult = try await request("agent.list")
        return result.agents
    }

    func request<Result: Decodable>(_ method: String) async throws -> Result {
        try await request(method, params: EmptyParams())
    }

    func request<Params: Encodable, Result: Decodable>(_ method: String, params: Params) async throws -> Result {
        let id = UUID().uuidString
        var line = try JSONEncoder().encode(RequestEnvelope(id: id, method: method, params: params))
        line.append(UInt8(ascii: "\n"))

        let socketPath = socketPath
        let timeout = timeout
        let request = line
        let reply = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, any Error>) in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(with: Swift.Result {
                    try UnixSocket.roundTrip(path: socketPath, request: request, timeout: timeout)
                })
            }
        }
        return try Self.decodeResponse(Result.self, from: reply, requestID: id)
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
}

struct EmptyParams: Encodable {}

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
