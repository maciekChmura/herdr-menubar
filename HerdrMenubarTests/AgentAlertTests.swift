import Testing
@testable import HerdrMenubar

struct AgentAlertTests {
    @Test func noAlertsForTheBaselineFetch() {
        let current = [agent("p1", .blocked), agent("p2", .done)]
        #expect(AgentAlert.alerts(previous: nil, current: current).isEmpty)
    }

    @Test func alertsWhenAnAgentGetsBlocked() {
        let alerts = AgentAlert.alerts(previous: [agent("p1", .working)], current: [agent("p1", .blocked)])
        #expect(alerts.map(\.kind) == [.blocked])
        #expect(alerts.map(\.agent.paneId) == ["p1"])
    }

    @Test func alertsWhenAnAgentFinishes() {
        let alerts = AgentAlert.alerts(previous: [agent("p1", .working)], current: [agent("p1", .done)])
        #expect(alerts.map(\.kind) == [.done])
    }

    @Test func alertsWhenABlockedAgentFinishes() {
        let alerts = AgentAlert.alerts(previous: [agent("p1", .blocked)], current: [agent("p1", .done)])
        #expect(alerts.map(\.kind) == [.done])
    }

    @Test(arguments: [
        (AgentStatus.working, AgentStatus.idle),
        (.blocked, .working),
        (.done, .idle),
        (.idle, .working),
        (.working, .unknown),
        (.done, .done),
        (.blocked, .blocked),
    ])
    func noAlertForOtherChanges(before: AgentStatus, after: AgentStatus) {
        #expect(AgentAlert.alerts(previous: [agent("p1", before)], current: [agent("p1", after)]).isEmpty)
    }

    @Test func noAlertForANewlyDetectedAgent() {
        let alerts = AgentAlert.alerts(previous: [agent("p1", .working)], current: [agent("p1", .working), agent("p2", .blocked)])
        #expect(alerts.isEmpty)
    }

    @Test func alertsForEachAgentThatChanged() {
        let previous = [agent("p1", .working), agent("p2", .working), agent("p3", .working)]
        let current = [agent("p1", .done), agent("p2", .working), agent("p3", .blocked)]
        let alerts = AgentAlert.alerts(previous: previous, current: current)
        #expect(alerts.map(\.agent.paneId) == ["p1", "p3"])
        #expect(alerts.map(\.kind) == [.done, .blocked])
    }

    @Test func titleNamesTheFolderAndBodyIsTheAgentTitle() {
        let blocked = AgentAlert(agent: agent("p1", .blocked, title: "Fix login tests", folder: "project-a"), kind: .blocked)
        #expect(blocked.title == "project-a: needs input")
        #expect(blocked.body == "Fix login tests")

        let done = AgentAlert(agent: agent("p1", .done, title: "Fix login tests", folder: "project-a"), kind: .done)
        #expect(done.title == "project-a: done")
    }

    @Test func titleUsesTheAgentTitleWhenThereIsNoFolder() {
        let alert = AgentAlert(agent: agent("p1", .done, title: "Fix login tests", folder: nil), kind: .done)
        #expect(alert.title == "Fix login tests: done")
    }

    @Test func skipsOnlyTheAgentTheUserIsLookingAt() {
        let focused = AgentAlert(agent: agent("p1", .done, focused: true), kind: .done)
        let other = AgentAlert(agent: agent("p2", .done, focused: false), kind: .done)

        #expect(focused.shouldPost(terminalIsFrontmost: true) == false)
        #expect(focused.shouldPost(terminalIsFrontmost: false))
        #expect(other.shouldPost(terminalIsFrontmost: true))
    }

    private func agent(
        _ pane: String,
        _ status: AgentStatus,
        title: String = "Task",
        folder: String? = "project",
        focused: Bool = false
    ) -> Agent {
        Agent(
            paneId: pane, workspaceId: "w1", tabId: "w1:t1", agent: "claude", name: nil,
            agentStatus: status, focused: focused,
            cwd: nil, foregroundCwd: folder.map { "/Users/me/dev/\($0)" },
            terminalTitleStripped: title
        )
    }
}
