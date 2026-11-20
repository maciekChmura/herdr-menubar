import Testing
@testable import HerdrMenubar

/// Which rex terminals are agents, and their state. See "Which terminals are agents" in `docs/PRD.md`.
struct RexAgentsTests {
    let claude = RexProcess(pid: 100, name: "2.1.329", cwd: "/Users/me/dev/project-a")

    @Test func aTerminalWhoseProgramReportsAStatusIsAnAgent() throws {
        let terminal = RexAgents.Terminal(
            sessionId: "session:1", blockId: "block:1", windowId: "window:1",
            records: [record("working", msg: "Running the test suite", owner: claude)],
            foreground: claude, title: " Fix login tests "
        )
        let agent = try #require(RexAgents.agent(for: terminal))

        #expect(agent.paneId == "block:1")
        #expect(agent.workspaceId == "session:1")
        #expect(agent.tabId == "window:1")
        #expect(agent.agentStatus == .working)
        #expect(agent.agent == "claude-code")
        #expect(agent.displayTitle == "Fix login tests")
        #expect(agent.folderName == "project-a")
        #expect(agent.message == "Running the test suite")
        #expect(agent.source == .rex)
        #expect(!agent.focused, "Rex can't say which session Rex.app shows")
    }

    @Test func aTerminalWithoutRecordsIsNoAgent() {
        #expect(RexAgents.agent(for: terminal([])) == nil)
    }

    @Test(arguments: ["idle", "working", "blocked"])
    func aRecordWhoseProgramIsGoneDoesntCount(state: String) {
        // The program reported, then exited back to the shell, which is now in the foreground.
        let shell = RexProcess(pid: 50, name: "zsh", cwd: "/Users/me")
        #expect(RexAgents.agent(for: terminal([record(state, owner: claude)], foreground: shell)) == nil)
        #expect(RexAgents.agent(for: terminal([record(state, owner: claude)], foreground: nil)) == nil)
    }

    @Test func aReusedPidDoesntCountAsTheSameProgram() {
        let other = RexProcess(pid: claude.pid, name: "vim")
        #expect(RexAgents.agent(for: terminal([record("idle", owner: claude)], foreground: other)) == nil)
    }

    @Test(arguments: ["done", "error"])
    func aFinishedRecordCountsAfterItsProgramExits(state: String) {
        let shell = RexProcess(pid: 50, name: "zsh")
        #expect(RexAgents.agent(for: terminal([record(state, owner: claude)], foreground: shell))?.agentStatus == .done)
    }

    @Test func recordsCountWhenTheForegroundIsUnknown() {
        var unknown = terminal([record("idle", owner: claude)], foreground: nil)
        unknown.foregroundKnown = false
        #expect(RexAgents.agent(for: unknown)?.agentStatus == .idle)
    }

    @Test func aRecordWithoutAnOwnerCounts() {
        #expect(RexAgents.agent(for: terminal([record("working", owner: nil)]))?.agentStatus == .working)
    }

    @Test func mapsRexStates() {
        #expect(RexAgents.status(of: "blocked") == .blocked)
        #expect(RexAgents.status(of: "working") == .working)
        #expect(RexAgents.status(of: "done") == .done)
        #expect(RexAgents.status(of: "error") == .done, "Failed and stopped: over, and not seen yet")
        #expect(RexAgents.status(of: "idle") == .idle)
        #expect(RexAgents.status(of: "sleeping") == .idle, "Rex's docs say to treat a state they don't know as idle")
    }

    @Test func theMostUrgentRecordWins() throws {
        let records = [
            record("idle", owner: claude),
            record("blocked", id: "worker", msg: "Approve deploy?", owner: claude),
            record("working", id: "build", msg: "Compiling", owner: claude),
        ]
        let agent = try #require(RexAgents.agent(for: terminal(records)))
        #expect(agent.agentStatus == .blocked)
        #expect(agent.message == "Approve deploy?")
    }

    @Test func fallsBackToTheProgramsNameWithoutATitle() {
        var untitled = terminal([record("idle", owner: claude)])
        untitled.title = nil
        #expect(RexAgents.agent(for: untitled)?.displayTitle == "claude-code")
    }

    @Test func shortensLongMessagesAndDropsEmptyOnes() throws {
        let long = String(repeating: "a", count: 200)
        let agent = try #require(RexAgents.agent(for: terminal([record("working", msg: long, owner: claude)])))
        #expect(agent.message?.count == RexAgents.maxMessageLength)
        #expect(agent.message?.hasSuffix("…") == true)

        #expect(RexAgents.agent(for: terminal([record("working", msg: "  ", owner: claude)]))?.message == nil)
    }

    /// A terminal where Claude Code is the foreground process.
    private func terminal(_ records: [RexStatusRecord]) -> RexAgents.Terminal {
        terminal(records, foreground: claude)
    }

    private func terminal(_ records: [RexStatusRecord], foreground: RexProcess?) -> RexAgents.Terminal {
        RexAgents.Terminal(sessionId: "session:1", blockId: "block:1", windowId: "window:1", records: records, foreground: foreground, title: "Task")
    }

    private func record(_ state: String, id: String? = nil, msg: String? = nil, owner: RexProcess?) -> RexStatusRecord {
        RexStatusRecord(id: id, state: state, kind: nil, effectiveApp: "claude-code", msg: msg, owner: owner)
    }
}
