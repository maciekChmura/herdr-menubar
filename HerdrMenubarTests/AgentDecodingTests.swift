import Foundation
import Testing
@testable import HerdrMenubar

struct AgentDecodingTests {
    static let repoRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()

    @Test func decodesTheCapturedAgentList() throws {
        let data = try Data(contentsOf: Self.repoRoot.appending(path: "docs/herdr/agent-list-example.json"))
        let agents = try HerdrClient.decodeResponse(AgentListResult.self, from: data, requestID: nil).agents

        #expect(agents.map(\.paneId) == ["w1:p6", "w1:p9", "w1:pA", "w1:pB"])
        #expect(agents.map(\.agentStatus) == [.working, .working, .idle, .working])
        #expect(agents.map(\.focused) == [false, false, false, true])

        let first = try #require(agents.first)
        #expect(first.agent == "claude")
        #expect(first.workspaceId == "w1")
        #expect(first.tabId == "w1:t5")
        #expect(first.cwd == "/Users/me/dev/project-a")
        #expect(first.foregroundCwd == "/Users/me/dev/project-a")
        #expect(first.displayTitle == "Example task 1")
    }

    @Test func decodesTheCapturedProcessInfo() throws {
        let data = try Data(contentsOf: Self.repoRoot.appending(path: "docs/herdr/process-info-example.json"))
        let info = try HerdrClient.decodeResponse(PaneProcessInfoResult.self, from: data, requestID: nil).processInfo

        #expect(info.paneId == "w1:pA")
        #expect(info.shellPid == 41001)
        #expect(info.foregroundProcessGroupId == 41020)
    }

    @Test func decodesProcessInfoForAPaneWithoutAForegroundGroup() throws {
        let line = Data(#"{"id":"1","result":{"type":"pane_process_info","process_info":{"pane_id":"w1:p1","foreground_processes":[]}}}"#.utf8)
        let info = try HerdrClient.decodeResponse(PaneProcessInfoResult.self, from: line, requestID: "1").processInfo
        #expect(info.foregroundProcessGroupId == nil)
    }

    @Test func agentsFromHerdrHaveNoBackgroundJobs() throws {
        #expect(try decodeAgent().backgroundJobs.isEmpty, "The app finds them; herdr doesn't report them")
    }

    @Test(arguments: ["blocked", "working", "done", "idle", "unknown"])
    func decodesEveryKnownStatus(raw: String) throws {
        let agent = try decodeAgent(status: raw)
        #expect(agent.agentStatus.rawValue == raw)
    }

    @Test func decodesAnUnrecognizedStatusAsUnknown() throws {
        #expect(try decodeAgent(status: "sleeping").agentStatus == .unknown)
    }

    @Test(arguments: [nil, "", "   "] as [String?])
    func displayTitleFallsBackToTheAgentType(title: String?) throws {
        #expect(try decodeAgent(title: title).displayTitle == "claude")
    }

    @Test func throwsTheServerErrorFromAnErrorResponse() {
        let line = Data(#"{"id":"1","error":{"code":"not_found","message":"no such agent"}}"#.utf8)
        #expect(throws: HerdrError.server(code: "not_found", message: "no such agent")) {
            try HerdrClient.decodeResponse(AgentListResult.self, from: line, requestID: "1")
        }
    }

    @Test func rejectsAReplyForADifferentRequest() {
        let line = Data(#"{"id":"other","result":{"agents":[]}}"#.utf8)
        #expect(throws: HerdrError.self) {
            try HerdrClient.decodeResponse(AgentListResult.self, from: line, requestID: "mine")
        }
    }

    private func decodeAgent(status: String = "idle", title: String? = "Some task") throws -> Agent {
        let titleJSON = title.map { "\"\($0)\"" } ?? "null"
        let line = Data("""
            {"id":"1","result":{"type":"agent_list","agents":[{
              "agent":"claude","agent_status":"\(status)","focused":false,
              "pane_id":"w1:p1","tab_id":"w1:t1","workspace_id":"w1",
              "terminal_id":"term_1","revision":1,"terminal_title_stripped":\(titleJSON)
            }]}}
            """.utf8)
        return try #require(HerdrClient.decodeResponse(AgentListResult.self, from: line, requestID: "1").agents.first)
    }
}
