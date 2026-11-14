import Testing
@testable import HerdrMenubar

struct MenuBarLabelTests {
    @Test func countsEachStateInDisplayOrder() {
        let agents = [agent(.idle), agent(.done), agent(.working), agent(.blocked), agent(.done), agent(.working), agent(.done)]
        #expect(MenuBarLabel(.loaded(agents)) == .counts("🔴1 🟢2 ✅3 ⚪1"))
    }

    @Test func leavesOutStatesWithNoAgents() {
        #expect(MenuBarLabel(.loaded([agent(.working), agent(.working)])) == .counts("🟢2"))
        #expect(MenuBarLabel(.loaded([agent(.blocked), agent(.idle)])) == .counts("🔴1 ⚪1"))
    }

    @Test func countsUnknownLast() {
        #expect(MenuBarLabel(.loaded([agent(.unknown), agent(.idle)])) == .counts("⚪1 ❔1"))
    }

    @Test func showsTheNoAgentsSymbolWhenThereAreNone() {
        #expect(MenuBarLabel(.loaded([])) == .symbol("circle.dashed"))
        #expect(MenuBarLabel(.loading) == .symbol("circle.dashed"))
    }

    @Test func showsTheUnreachableSymbolWhenHerdrCantBeRead() {
        #expect(MenuBarLabel(.notRunning) == .symbol("exclamationmark.circle"))
        #expect(MenuBarLabel(.failed("timed out")) == .symbol("exclamationmark.circle"))
    }

    private func agent(_ status: AgentStatus) -> Agent {
        Agent(
            paneId: "w1:p\(Int.random(in: 0..<1_000_000))", workspaceId: "w1", tabId: "w1:t1",
            agent: "claude", name: nil, agentStatus: status, focused: false,
            cwd: nil, foregroundCwd: nil, terminalTitleStripped: nil
        )
    }
}
