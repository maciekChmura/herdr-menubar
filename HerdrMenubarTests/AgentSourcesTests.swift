import Testing
@testable import HerdrMenubar

/// herdr and rex side by side. See "Menu bar label" and "Dropdown" in `docs/PRD.md`.
struct AgentSourcesTests {
    let herdrAgent = Self.agent("w1:p1", .herdr)
    let rexAgent = Self.agent("block:1", .rex)

    @Test func theMenuBarShowsBothServersAgentsHerdrsFirst() {
        let sources = AgentSources(herdr: .loaded([herdrAgent]), rex: .loaded([rexAgent]))
        #expect(sources.combined == .loaded([herdrAgent, rexAgent]))
    }

    @Test func oneServerThatIsntRunningIsNormal() {
        #expect(AgentSources(herdr: .notRunning, rex: .loaded([rexAgent])).combined == .loaded([rexAgent]))
        #expect(AgentSources(herdr: .loaded([herdrAgent]), rex: .notRunning).combined == .loaded([herdrAgent]))
        #expect(AgentSources(herdr: .loaded([herdrAgent]), rex: .failed("timedOut")).combined == .loaded([herdrAgent]))
        #expect(AgentSources(herdr: .loaded([]), rex: .notRunning).combined == .loaded([]))
    }

    @Test func withoutAnyServerThatCouldBeReadItSaysWhy() {
        #expect(AgentSources(herdr: .notRunning, rex: .notRunning).combined == .notRunning)
        #expect(AgentSources(herdr: .notRunning, rex: .failed("timedOut")).combined == .failed("timedOut"))
        #expect(AgentSources(herdr: .loading, rex: .failed("timedOut")).combined == .loading)
        #expect(MenuBarLabel(AgentSources(herdr: .notRunning, rex: .notRunning).combined, style: .counts) == .symbol(MenuBarLabel.unreachableSymbol))
    }

    @Test func findsAnAgentInEitherServer() {
        let sources = AgentSources(herdr: .loaded([herdrAgent]), rex: .loaded([rexAgent]))
        #expect(sources.agent(withPaneId: "block:1")?.source == .rex)
        #expect(sources.agent(withPaneId: "w1:p1")?.source == .herdr)
        #expect(sources.agent(withPaneId: "w9:p9") == nil)
    }

    @Test func theDropdownHasASectionForEachServerWithSomethingToShow() {
        let sources = AgentSources(herdr: .loaded([]), rex: .loading)
        #expect(sources.sections.map(\.source) == [.rex])
        #expect(AgentSources(herdr: .failed("x"), rex: .loaded([rexAgent])).sections.map(\.source) == [.herdr, .rex])
        #expect(AgentSources(herdr: .notRunning, rex: .notRunning).sections.isEmpty)
    }

    private static func agent(_ pane: String, _ source: AgentSource) -> Agent {
        Agent(
            paneId: pane, workspaceId: "w", tabId: "t", agent: "claude", name: nil, agentStatus: .working, focused: false,
            cwd: nil, foregroundCwd: nil, terminalTitleStripped: "Task", source: source
        )
    }
}
