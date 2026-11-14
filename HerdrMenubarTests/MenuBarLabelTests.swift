import Testing
@testable import HerdrMenubar

struct MenuBarLabelTests {
    @Test func countsEachStateInDisplayOrder() {
        let agents = [agent(.idle), agent(.done), agent(.working), agent(.blocked), agent(.done), agent(.working), agent(.done)]
        #expect(MenuBarLabel(.loaded(agents), style: .counts) == .counts([
            StatusCount(status: .blocked, count: 1), StatusCount(status: .working, count: 2),
            StatusCount(status: .done, count: 3), StatusCount(status: .idle, count: 1),
        ]))
    }

    @Test func leavesOutStatesWithNoAgents() {
        #expect(MenuBarLabel(.loaded([agent(.working), agent(.working)]), style: .counts)
            == .counts([StatusCount(status: .working, count: 2)]))
        #expect(MenuBarLabel(.loaded([agent(.blocked), agent(.idle)]), style: .counts)
            == .counts([StatusCount(status: .blocked, count: 1), StatusCount(status: .idle, count: 1)]))
    }

    @Test func countsUnknownLast() {
        #expect(MenuBarLabel(.loaded([agent(.unknown), agent(.idle)]), style: .counts)
            == .counts([StatusCount(status: .idle, count: 1), StatusCount(status: .unknown, count: 1)]))
    }

    @Test func showsOneDotPerAgentInHerdrsOrder() {
        let agents = [agent(.working), agent(.blocked), agent(.done), agent(.idle), agent(.unknown), agent(.working)]
        #expect(MenuBarLabel(.loaded(agents), style: .dots) == .dots([.working, .blocked, .done, .idle, .unknown, .working]))
    }

    @Test func aDotKeepsItsPlaceWhenItsAgentChangesState() {
        let before = [agent(.working, pane: "a"), agent(.working, pane: "b"), agent(.working, pane: "c")]
        let after = [agent(.working, pane: "a"), agent(.blocked, pane: "b"), agent(.working, pane: "c")]
        #expect(MenuBarLabel(.loaded(before), style: .dots) == .dots([.working, .working, .working]))
        #expect(MenuBarLabel(.loaded(after), style: .dots) == .dots([.working, .blocked, .working]))
    }

    @Test func spokenSummaryNamesEachStateInDisplayOrder() {
        let counts = MenuBarLabel.statusCounts(of: [.idle, .working, .blocked, .working])
        #expect(MenuBarLabel.spokenSummary(of: counts) == "1 blocked, 2 working, 1 idle")
    }

    @Test func logSummaryStillUsesTheGlyphs() {
        #expect(MenuBarLabel.counts(of: [agent(.done), agent(.working), agent(.done)]) == "🟢1 🔵2")
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

    private func agent(_ status: AgentStatus, pane: String? = nil) -> Agent {
        Agent(
            paneId: pane ?? "w1:p\(Int.random(in: 0..<1_000_000))", workspaceId: "w1", tabId: "w1:t1",
            agent: "claude", name: nil, agentStatus: status, focused: false,
            cwd: nil, foregroundCwd: nil, terminalTitleStripped: nil
        )
    }
}
