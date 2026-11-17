import Darwin
import Foundation
import Testing
@testable import HerdrMenubar

/// Finding an agent's background jobs in a process table. See "Background jobs" in `docs/PRD.md`.
struct BackgroundJobsTests {
    let now = Date(timeIntervalSince1970: 1_000_000)

    /// An agent (group 100) with an MCP server and `caffeinate` in its group, one background job running
    /// `sleep 240`, and another agent's job.
    var table: [RunningProcess] {
        [
            process(100, parent: 50, group: 100, age: 3600),  // the agent
            process(101, parent: 100, group: 100, age: 3500), // its MCP server
            process(102, parent: 100, group: 100, age: 30),   // caffeinate
            process(150, parent: 100, group: 150, age: 120),  // the job's shell
            process(151, parent: 150, group: 150, age: 119),  // sleep 240
            process(200, parent: 60, group: 200, age: 3600),  // another agent
            process(250, parent: 200, group: 250, age: 60),   // its job
        ]
    }

    let arguments: [Int32: [String]] = [
        150: ["/bin/zsh", "-c", "source ~/.claude/shell-snapshots/snapshot.sh && eval 'sleep 240'"],
        151: ["/bin/sleep", "240"],
    ]

    @Test func findsProcessesTheAgentStartedInAGroupOfTheirOwn() {
        let scan = BackgroundJobs.scan(agentGroup: 100, in: table, now: now) { arguments[$0] }

        #expect(scan.jobs == [BackgroundJob(pid: 150, command: "sleep 240", startDate: now - 120)])
        #expect(scan.recheckDate == nil)
    }

    @Test func leavesOutProcessesInTheAgentsOwnGroup() {
        // Without the job, only the MCP server and caffeinate are left, and they're in the agent's group.
        let scan = BackgroundJobs.scan(agentGroup: 100, in: table.filter { $0.groupId != 150 }, now: now) { arguments[$0] }
        #expect(scan.jobs.isEmpty)
    }

    @Test func findsNothingForAGroupThatIsGone() {
        #expect(BackgroundJobs.scan(agentGroup: 999, in: table, now: now) { arguments[$0] }.jobs.isEmpty)
    }

    @Test func findsJobsStartedByAnyProcessInTheAgentsGroup() {
        // The MCP server, not the agent, started this one.
        let table = table + [process(160, parent: 101, group: 160, age: 10)]
        let scan = BackgroundJobs.scan(agentGroup: 100, in: table, now: now) { _ in ["/usr/bin/make", "export"] }
        #expect(scan.jobs.map(\.pid) == [150, 160], "Oldest first")
    }

    @Test func skipsJobsYoungerThanTheMinimumAgeAndSaysWhenToLookAgain() {
        // Like Claude Code's status line, which runs for well under a second.
        let table = table + [
            process(170, parent: 100, group: 170, age: 0.3),
            process(171, parent: 100, group: 171, age: 2),
        ]
        let scan = BackgroundJobs.scan(agentGroup: 100, in: table, now: now) { arguments[$0] }

        #expect(scan.jobs.map(\.pid) == [150])
        #expect(scan.recheckDate == now + BackgroundJobs.minimumAge - 2, "When the older of the two becomes old enough")
    }

    @Test func skipsZombies() {
        var zombie = process(180, parent: 100, group: 180, age: 60)
        zombie.isZombie = true
        let scan = BackgroundJobs.scan(agentGroup: 100, in: table + [zombie], now: now) { arguments[$0] }
        #expect(scan.jobs.map(\.pid) == [150])
    }

    @Test func looksUnderSubshellsForTheCommand() {
        // `( time npm run render )`: the job's shell starts a subshell, which starts npm.
        let table = table.filter { $0.pid != 151 } + [
            process(152, parent: 150, group: 150, age: 119),
            process(153, parent: 152, group: 150, age: 119),
            process(154, parent: 153, group: 150, age: 118),
        ]
        let arguments: [Int32: [String]] = [
            150: ["/bin/zsh", "-c", "source snapshot.sh && eval '( time npm run render )'"],
            152: ["/bin/zsh", "-c", "source snapshot.sh && eval '( time npm run render )'"],
            153: ["npm", "run", "render"],
            154: ["node", "/opt/project/node_modules/.bin/tsx", "src/render.ts"],
        ]
        let scan = BackgroundJobs.scan(agentGroup: 100, in: table, now: now) { arguments[$0] }
        #expect(scan.jobs.map(\.command) == ["npm run render"])
    }

    @Test func namesAJobThatHasNotStartedAnythingAfterItsShell() {
        let scan = BackgroundJobs.scan(agentGroup: 100, in: table.filter { $0.pid != 151 }, now: now) { arguments[$0] }
        #expect(scan.jobs.map(\.command) == ["zsh"])
    }

    @Test func namesAJobWhoseArgumentsCanNotBeRead() {
        let scan = BackgroundJobs.scan(agentGroup: 100, in: table, now: now) { _ in nil }
        #expect(scan.jobs.map(\.command) == ["unknown command"])
    }

    @Test(arguments: [
        (["/bin/sleep", "240"], "sleep 240"),
        (["/usr/local/bin/node", "/opt/homebrew/bin/npm", "test"], "npm test"),
        (["/opt/homebrew/Cellar/python@3.13/Python", "/Users/me/dev/project/export.py", "--all"], "export.py --all"),
        (["python3", "export.py"], "python3 export.py"),
        (["/bin/zsh", "-c", "npm test 2>&1 | tail -50"], "zsh -c …"),
        (["cargo", "test", "--target-dir=/tmp/target"], "cargo test --target-dir=/tmp/target"),
        (["xcodebuild", "-scheme", "HerdrMenubar", "-configuration", "Debug", "-derivedDataPath", "build", "test"],
         "xcodebuild -scheme HerdrMenubar -config…"),
        ([], "unknown command"),
    ])
    func shortensTheCommand(argv: [String], expected: String) {
        #expect(BackgroundJobs.command(from: argv) == expected)
    }

    @Test(arguments: [(0, "0s"), (45, "45s"), (60, "1m"), (12 * 60 + 59, "12m"), (3600, "1h"), (3600 + 5 * 60, "1h 5m")] as [(TimeInterval, String)])
    func formatsHowLongAJobHasRun(seconds: TimeInterval, expected: String) {
        #expect(BackgroundJobs.duration(from: now - seconds, to: now) == expected)
    }

    private func process(_ pid: Int32, parent: Int32, group: Int32, age: TimeInterval) -> RunningProcess {
        RunningProcess(pid: pid, parentPid: parent, groupId: group, startDate: now - age)
    }
}

/// Reads the real process table with a child process this test starts in a group of its own,
/// the way Claude Code starts a background command.
struct ProcessTableTests {
    @Test func findsAChildStartedInAGroupOfItsOwn() async throws {
        let shell = try spawnInOwnGroup(["/bin/sh", "-c", "/bin/sleep 30; true"])
        defer {
            kill(-shell, SIGKILL)
            var status: Int32 = 0
            waitpid(shell, &status, 0)
        }

        // Wait for the shell to start sleep.
        var table: [RunningProcess] = []
        for _ in 0..<200 {
            table = ProcessTable.all()
            if table.contains(where: { $0.parentPid == shell }) { break }
            try await Task.sleep(for: .milliseconds(10))
        }

        let entry = try #require(table.first { $0.pid == shell })
        #expect(entry.parentPid == getpid())
        #expect(entry.groupId == shell)
        #expect(abs(entry.startDate.timeIntervalSinceNow) < 10)
        #expect(ProcessTable.arguments(of: shell) == ["/bin/sh", "-c", "/bin/sleep 30; true"])

        // Pretend it's been running for a minute.
        let scan = BackgroundJobs.scan(agentGroup: getpgrp(), in: table, now: Date() + 60, arguments: ProcessTable.arguments(of:))
        let job = try #require(scan.jobs.first { $0.pid == shell })
        #expect(job.command == "sleep 30")
    }

    @Test func listsThisProcess() throws {
        let me = try #require(ProcessTable.all().first { $0.pid == getpid() })
        #expect(me.parentPid == getppid())
        #expect(me.groupId == getpgrp())
        #expect(!me.isZombie)
    }

    @Test func readsNoArgumentsForAProcessThatDoesNotExist() {
        #expect(ProcessTable.arguments(of: -1) == nil)
    }

    @Test func parsesProcArgsLikeTheKernelWritesThem() {
        var bytes: [UInt8] = []
        withUnsafeBytes(of: Int32(2)) { bytes += $0 }
        bytes += Array("/bin/sleep".utf8) + [0, 0, 0]
        bytes += Array("sleep".utf8) + [0] + Array("240".utf8) + [0]
        bytes += Array("HOME=/Users/me".utf8) + [0]
        #expect(ProcessTable.parseProcArgs(bytes[...]) == ["sleep", "240"])
    }

    private func spawnInOwnGroup(_ argv: [String]) throws -> pid_t {
        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP))
        posix_spawnattr_setpgroup(&attributes, 0)

        var cArguments = argv.map { strdup($0) } + [nil]
        defer { cArguments.forEach { free($0) } }
        var pid: pid_t = 0
        let result = posix_spawn(&pid, argv[0], nil, &attributes, &cArguments, environ)
        guard result == 0 else { throw HerdrError.io(errno: result) }
        return pid
    }
}
