import Foundation
import Observation
import OSLog

/// What the app currently knows about herdr's agents.
@MainActor
@Observable
final class AgentStore {
    enum State: Equatable {
        case loading
        case notRunning
        case failed(String)
        case loaded([Agent])
    }

    private(set) var state: State = .loading
    private let client: HerdrClient
    private let log = Logger(subsystem: "io.github.maciekchmura.HerdrMenubar", category: "herdr")

    init(client: HerdrClient) {
        self.client = client
    }

    func refresh() async {
        do {
            let agents = try await client.listAgents()
            log.info("Loaded \(agents.count) agents")
            state = .loaded(agents)
        } catch HerdrError.notRunning {
            log.info("herdr server is not running at \(self.client.socketPath, privacy: .public)")
            state = .notRunning
        } catch {
            log.error("Couldn't list agents: \(String(describing: error), privacy: .public)")
            state = .failed(String(describing: error))
        }
    }
}
