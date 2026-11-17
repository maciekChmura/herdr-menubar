import AppKit
import Testing
@testable import HerdrMenubar

@MainActor
struct StatusMenuTests {
    let settings = StatusMenu.Settings(
        style: .dots,
        animationTitle: "Animate dots",
        animationOn: true,
        launchAtLoginTitle: "Launch at login",
        launchAtLoginOn: false,
        checkForUpdatesOn: true
    )

    @Test func listsAgentsUnderAHeaderWithTheFocusedOneChecked() throws {
        let agents = [
            agent("w1:p1", .idle, title: "Write docs", folder: "docs-site", focused: true),
            agent("w1:p2", .blocked, title: "Fix login", folder: "web"),
        ]
        let items = StatusMenu.items(for: .loaded(agents), settings: settings, target: nil)

        #expect(items[0].title == "2 agents")
        #expect(items[0].action == nil, "The header can't be clicked")
        #expect(items[1].isSeparatorItem)

        let rows = Array(items[2...3])
        #expect(rows.map(\.title) == ["Write docs — docs-site", "Fix login — web"], "In dots mode, rows follow the dots")
        #expect(rows.map { $0.representedObject as? String } == ["w1:p1", "w1:p2"])
        #expect(rows.map(\.state) == [.on, .off])
        #expect(rows.allSatisfy { $0.image != nil && $0.action == #selector(StatusItemController.selectAgent(_:)) })
        if #available(macOS 27, *) {
            #expect(rows.allSatisfy { $0.preferredImageVisibility == .visible }, "Otherwise macOS 27 hides the dots")
        }
    }

    @Test func listsAnAgentsBackgroundJobsUnderItsRow() throws {
        let now = Date(timeIntervalSince1970: 1_000_000)
        var waiting = agent("w1:p1", .done, title: "Export data")
        waiting.backgroundJobs = [BackgroundJob(pid: 10, command: "python3 export.py", startDate: now - 600)]
        let items = StatusMenu.items(for: .loaded([waiting, agent("w1:p2", .idle)]), settings: settings, target: nil, now: now)

        let rows = Array(items[2...3])
        if #available(macOS 14.4, *) {
            #expect(rows[0].subtitle == "In background: python3 export.py (10m)")
            #expect(rows[1].subtitle == nil)
        } else {
            #expect(rows[0].toolTip == "In background: python3 export.py (10m)")
        }
        #expect(rows[0].title == "Export data — project", "The title stays as it was")
    }

    @Test func inCountsModeRowsAreSortedByStateLikeTheCounts() {
        var countsSettings = settings
        countsSettings.style = .counts
        let agents = [agent("w1:p1", .idle, title: "Write docs"), agent("w1:p2", .blocked, title: "Fix login")]
        let items = StatusMenu.items(for: .loaded(agents), settings: countsSettings, target: nil)

        #expect(items[2...3].map { $0.representedObject as? String } == ["w1:p2", "w1:p1"], "Blocked agents come first")
    }

    @Test func showsTheSettingsAndQuitAfterTheAgents() throws {
        let items = StatusMenu.items(for: .loaded([agent("w1:p1", .idle)]), settings: settings, target: nil)
        let tail = Array(items.suffix(6))

        #expect(tail[0].isSeparatorItem)
        #expect(tail[1].title == "Menu bar shows")
        let styles = try #require(tail[1].submenu?.items)
        #expect(styles.map(\.title) == ["Counts per state", "One dot per agent"])
        #expect(styles.map(\.state) == [.off, .on])

        #expect(tail[2].title == "Animate dots")
        #expect(tail[2].state == .on)
        #expect(tail[3].title == "Launch at login")
        #expect(tail[3].state == .off)
        #expect(tail[4].title == "Check for updates")
        #expect(tail[4].state == .on)
        #expect(tail[4].action == #selector(StatusItemController.toggleCheckForUpdates(_:)))
        #expect(tail[5].title == "Quit")
        #expect(tail[5].keyEquivalent == "q")
    }

    @Test func offersAnUpdateAtTheTop() throws {
        var withUpdate = settings
        let page = try #require(URL(string: "https://github.com/maciekChmura/herdr-menubar/releases/tag/v0.2.0"))
        withUpdate.update = UpdateChecker.Update(version: "0.2.0", url: page)
        let items = StatusMenu.items(for: .notRunning, settings: withUpdate, target: nil)

        #expect(items[0].title == "Update available: 0.2.0…")
        #expect(items[0].action == #selector(StatusItemController.openUpdate(_:)))
        #expect(items[0].representedObject as? URL == page)
        #expect(items[1].isSeparatorItem)
        #expect(items[2].title == "herdr server is not running")
    }

    @Test func offersNoUpdateWhenThereIsNone() {
        let items = StatusMenu.items(for: .loaded([]), settings: settings, target: nil)
        #expect(!items.contains { $0.action == #selector(StatusItemController.openUpdate(_:)) })
    }

    @Test func explainsWhenHerdrIsNotRunning() {
        let items = StatusMenu.items(for: .notRunning, settings: settings, target: nil)
        #expect(items.prefix(2).map(\.title) == ["herdr server is not running", "Start it by running \"herdr\" in a terminal"])
        #expect(items.prefix(2).allSatisfy { $0.action == nil })
    }

    @Test func saysSoWhenThereAreNoAgents() {
        let items = StatusMenu.items(for: .loaded([]), settings: settings, target: nil)
        #expect(items[0].title == "No agents")
        #expect(items[1].isSeparatorItem)
        #expect(items[2].title == "Menu bar shows")
    }

    private func agent(_ pane: String, _ status: AgentStatus, title: String = "Task", folder: String = "project", focused: Bool = false) -> Agent {
        Agent(
            paneId: pane, workspaceId: "w1", tabId: "w1:t1", agent: "claude", name: nil,
            agentStatus: status, focused: focused,
            cwd: nil, foregroundCwd: "/Users/me/dev/\(folder)", terminalTitleStripped: title
        )
    }
}
