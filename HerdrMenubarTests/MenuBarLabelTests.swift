import Foundation
import Testing
@testable import HerdrMenubar

struct MenuBarLabelTests {
    @Test func countsEachStateInDisplayOrder() {
        let agents = [agent(.idle), agent(.done), agent(.working), agent(.blocked), agent(.done), agent(.working), agent(.done)]
        #expect(MenuBarLabel(.loaded(agents), style: .counts) == .counts([
            StatusCount(status: .blocked, count: 1), StatusCount(status: .working, count: 2),
            StatusCount(status: .done, count: 3), StatusCount(status: .idle, count: 1),
        ], inBackground: 0))
    }

    @Test func leavesOutStatesWithNoAgents() {
        #expect(MenuBarLabel(.loaded([agent(.working), agent(.working)]), style: .counts)
            == .counts([StatusCount(status: .working, count: 2)], inBackground: 0))
        #expect(MenuBarLabel(.loaded([agent(.blocked), agent(.idle)]), style: .counts)
            == .counts([StatusCount(status: .blocked, count: 1), StatusCount(status: .idle, count: 1)], inBackground: 0))
    }

    @Test func countsUnknownLast() {
        #expect(MenuBarLabel(.loaded([agent(.unknown), agent(.idle)]), style: .counts)
            == .counts([StatusCount(status: .idle, count: 1), StatusCount(status: .unknown, count: 1)], inBackground: 0))
    }

    @Test func showsOneDotPerAgentInHerdrsOrder() {
        let agents = [agent(.working), agent(.blocked), agent(.done), agent(.idle), agent(.unknown), agent(.working)]
        #expect(dotStatuses(MenuBarLabel(.loaded(agents), style: .dots)) == [.working, .blocked, .done, .idle, .unknown, .working])
    }

    @Test func aDotKeepsItsPlaceWhenItsAgentChangesState() {
        let before = [agent(.working, pane: "a"), agent(.working, pane: "b"), agent(.working, pane: "c")]
        let after = [agent(.working, pane: "a"), agent(.blocked, pane: "b"), agent(.working, pane: "c")]
        #expect(MenuBarLabel(.loaded(before), style: .dots) == .dots([
            PaneStatus(paneId: "a", status: .working), PaneStatus(paneId: "b", status: .working), PaneStatus(paneId: "c", status: .working),
        ]))
        #expect(MenuBarLabel(.loaded(after), style: .dots) == .dots([
            PaneStatus(paneId: "a", status: .working), PaneStatus(paneId: "b", status: .blocked), PaneStatus(paneId: "c", status: .working),
        ]))
    }

    @Test func countsAgentsWithBackgroundJobsOnTopOfTheirState() {
        let agents = [agent(.done, jobs: 1), agent(.idle, jobs: 2), agent(.working), agent(.done)]
        #expect(MenuBarLabel(.loaded(agents), style: .counts) == .counts([
            StatusCount(status: .working, count: 1), StatusCount(status: .done, count: 2), StatusCount(status: .idle, count: 1),
        ], inBackground: 2))
    }

    @Test func marksTheDotsOfAgentsWithBackgroundJobs() {
        let agents = [agent(.working, pane: "a"), agent(.done, pane: "b", jobs: 1), agent(.idle, pane: "c")]
        #expect(MenuBarLabel(.loaded(agents), style: .dots) == .dots([
            PaneStatus(paneId: "a", status: .working),
            PaneStatus(paneId: "b", status: .done, hasBackgroundJobs: true),
            PaneStatus(paneId: "c", status: .idle),
        ]))
    }

    @Test(arguments: [
        ([AgentStatus.blocked, .working, .done], 2),
        ([AgentStatus.blocked], 1),
        ([AgentStatus.done, .idle], 0),
        ([AgentStatus](), 0),
    ])
    func theBackgroundCountGoesAfterBlockedAndWorking(statuses: [AgentStatus], expected: Int) {
        #expect(MenuBarLabel.backgroundIndex(in: MenuBarLabel.statusCounts(of: statuses)) == expected)
    }

    @Test func spokenSummaryNamesEachStateInDisplayOrder() {
        let counts = MenuBarLabel.statusCounts(of: [.idle, .working, .blocked, .working])
        #expect(MenuBarLabel.spokenSummary(of: counts) == "1 blocked, 2 working, 1 idle")
        #expect(MenuBarLabel.spokenSummary(of: counts, inBackground: 1) == "1 blocked, 2 working, 1 with background jobs, 1 idle")
    }

    @Test func logSummaryStillUsesTheGlyphs() {
        #expect(MenuBarLabel.counts(of: [agent(.done), agent(.working), agent(.done)]) == "🟢1 🔵2")
        #expect(MenuBarLabel.counts(of: [agent(.done, jobs: 1), agent(.working)]) == "🟢1 🔵1 ⏳1")
    }

    @Test(arguments: MenuBarStyle.allCases)
    func showsTheNoAgentsSymbolWhenThereAreNone(style: MenuBarStyle) {
        #expect(MenuBarLabel(.loaded([]), style: style) == .symbol("circle.dashed"))
        #expect(MenuBarLabel(.loading, style: style) == .symbol("circle.dashed"))
    }

    @Test(arguments: MenuBarStyle.allCases)
    func showsTheUnreachableSymbolWhenHerdrCantBeRead(style: MenuBarStyle) {
        #expect(MenuBarLabel(.notRunning, style: style) == .symbol("exclamationmark.circle"))
        #expect(MenuBarLabel(.failed("timed out"), style: style) == .symbol("exclamationmark.circle"))
    }

    private func dotStatuses(_ label: MenuBarLabel) -> [AgentStatus]? {
        guard case .dots(let panes) = label else { return nil }
        return panes.map(\.status)
    }

    private func agent(_ status: AgentStatus, pane: String? = nil, jobs: Int = 0) -> Agent {
        Agent(
            paneId: pane ?? "w1:p\(Int.random(in: 0..<1_000_000))", workspaceId: "w1", tabId: "w1:t1",
            agent: "claude", name: nil, agentStatus: status, focused: false,
            cwd: nil, foregroundCwd: nil, terminalTitleStripped: nil,
            backgroundJobs: (0..<jobs).map { BackgroundJob(pid: Int32(100 + $0), command: "sleep 240", startDate: Date()) }
        )
    }
}
