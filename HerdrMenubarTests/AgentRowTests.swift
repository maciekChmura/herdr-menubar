import Foundation
import Testing
@testable import HerdrMenubar

struct AgentRowTests {
    @Test func sortsByStateInDisplayOrderThenByFolder() {
        let agents = [
            agent("p1", .idle, folder: "alpha"),
            agent("p2", .working, folder: "zeta"),
            agent("p3", .unknown, folder: "alpha"),
            agent("p4", .done, folder: "beta"),
            agent("p5", .working, folder: "Alpha2"),
            agent("p6", .blocked, folder: "omega"),
            agent("p7", .working, folder: "alpha10"),
        ]
        // Folders compare like Finder does: case-insensitive, with numbers by value.
        #expect(AgentRow.rows(for: agents).map(\.id) == ["p6", "p5", "p7", "p2", "p4", "p1", "p3"])
    }

    @Test func followsTheMenuBarStyle() {
        let agents = [agent("p1", .idle, folder: "a"), agent("p2", .blocked, folder: "b"), agent("p3", .working, folder: "c")]
        #expect(AgentRow.rows(for: agents, matching: .dots).map(\.id) == ["p1", "p2", "p3"], "Same order as the dots")
        #expect(AgentRow.rows(for: agents, matching: .counts).map(\.id) == ["p2", "p3", "p1"], "Same order as the counts")
    }

    @Test func breaksTiesByPaneSoTheOrderIsStable() {
        let agents = [agent("p9", .working, folder: "same"), agent("p1", .working, folder: "same")]
        #expect(AgentRow.rows(for: agents).map(\.id) == ["p1", "p9"])
    }

    @Test func sortsTheCapturedAgentList() throws {
        let data = try Data(contentsOf: AgentDecodingTests.repoRoot.appending(path: "docs/herdr/agent-list-example.json"))
        let agents = try HerdrClient.decodeResponse(AgentListResult.self, from: data, requestID: nil).agents

        let rows = AgentRow.rows(for: agents)

        #expect(rows.map(\.id) == ["w1:p6", "w1:p9", "w1:pB", "w1:pA"])
        #expect(rows.map(\.title) == [
            "Example task 1 — project-a",
            "Example task 2 — project-b",
            "Example task 4 — project-d",
            "Example task 3 — project-c",
        ])
        #expect(rows.map(\.agent.focused) == [false, false, true, false])
    }

    @Test func showsTitleAndFolder() {
        let row = AgentRow(agent: agent("p1", .blocked, title: "Fix login tests", folder: "project-a"))
        #expect(row.title == "Fix login tests — project-a")
    }

    @Test func fallsBackToTheAgentTypeWhenThereIsNoTitle() {
        let row = AgentRow(agent: agent("p1", .done, title: nil, folder: "project-a"))
        #expect(row.title == "claude — project-a")
    }

    @Test func takesTheFolderFromCwdWhenThereIsNoForegroundCwd() {
        let fromCwd = Agent(
            paneId: "p1", workspaceId: "w1", tabId: "w1:t1", agent: "claude", name: nil,
            agentStatus: .idle, focused: false, cwd: "/Users/me/dev/fallback", foregroundCwd: nil,
            terminalTitleStripped: "Task"
        )
        #expect(AgentRow(agent: fromCwd).title == "Task — fallback")
    }

    @Test func leavesOutTheFolderWhenThereIsNoDirectory() {
        let row = AgentRow(agent: agent("p1", .idle, title: "Task", folder: nil))
        #expect(row.title == "Task")
    }

    @Test(arguments: [(0, "No agents"), (1, "1 agent"), (4, "4 agents")])
    func header(count: Int, expected: String) {
        #expect(AgentRow.header(agentCount: count) == expected)
    }

    private func agent(_ pane: String, _ status: AgentStatus, title: String? = "Task", folder: String?) -> Agent {
        Agent(
            paneId: pane, workspaceId: "w1", tabId: "w1:t1", agent: "claude", name: nil,
            agentStatus: status, focused: false,
            cwd: nil, foregroundCwd: folder.map { "/Users/me/dev/\($0)" },
            terminalTitleStripped: title
        )
    }
}
