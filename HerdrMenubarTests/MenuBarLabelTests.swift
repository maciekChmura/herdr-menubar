import Testing
@testable import HerdrMenubar

struct MenuBarLabelTests {
    @Test func countsEachStateInDisplayOrder() {
        let agents = [agent(.idle), agent(.done), agent(.working), agent(.blocked), agent(.done), agent(.working), agent(.done)]
        #expect(MenuBarLabel(.loaded(agents), style: .counts) == .text("🔴1 🟢2 🔵3 ⚪1"))
    }

    @Test func leavesOutStatesWithNoAgents() {
        #expect(MenuBarLabel(.loaded([agent(.working), agent(.working)]), style: .counts) == .text("🟢2"))
        #expect(MenuBarLabel(.loaded([agent(.blocked), agent(.idle)]), style: .counts) == .text("🔴1 ⚪1"))
    }

    @Test func countsUnknownLast() {
        #expect(MenuBarLabel(.loaded([agent(.unknown), agent(.idle)]), style: .counts) == .text("⚪1 ⚫1"))
    }

    @Test func showsOneDotPerAgentInHerdrsOrder() {
        let agents = [agent(.working), agent(.blocked), agent(.done), agent(.idle), agent(.unknown), agent(.working)]
        #expect(MenuBarLabel(.loaded(agents), style: .dots) == .text("🟢🔴🔵⚪⚫🟢"))
    }

    @Test func aDotKeepsItsPlaceWhenItsAgentChangesState() {
        let before = [agent(.working, pane: "a"), agent(.working, pane: "b"), agent(.working, pane: "c")]
        let after = [agent(.working, pane: "a"), agent(.blocked, pane: "b"), agent(.working, pane: "c")]
        #expect(MenuBarLabel(.loaded(before), style: .dots) == .text("🟢🟢🟢"))
        #expect(MenuBarLabel(.loaded(after), style: .dots) == .text("🟢🔴🟢"))
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
