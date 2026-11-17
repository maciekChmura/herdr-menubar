import Foundation

/// A command an agent left running in the background, such as a long test run.
/// See "Background jobs" in `docs/PRD.md`.
struct BackgroundJob: Equatable, Sendable {
    /// The job's own process: the shell the agent started the command in.
    let pid: Int32
    /// What's running, such as "npm test".
    let command: String
    let startDate: Date
}

/// One process from the process table. See `ProcessTable`.
struct RunningProcess: Equatable, Sendable {
    let pid: Int32
    let parentPid: Int32
    /// The process group.
    let groupId: Int32
    let startDate: Date
    var isZombie = false
}

/// Finds an agent's background jobs in the process table.
enum BackgroundJobs {
    /// Younger processes don't count. Claude Code's status line and hooks also run in process groups
    /// of their own, but for well under a second.
    static let minimumAge: TimeInterval = 5

    /// Commands longer than this are cut short with "…".
    static let maxCommandLength = 40

    /// Interpreters that run a script by its path. When a script is run through its `#!` line, the
    /// interpreter comes first, as in `node /opt/homebrew/bin/npm test`, and is left out of the command.
    /// Any name starting with "python" counts too, such as "python3.13" or Homebrew's "Python".
    static let interpreters: Set<String> = ["node", "bun", "deno", "ruby", "perl", "bash", "sh", "zsh"]

    /// Shells a job's command can run in. The command shown is the first process under them that isn't one.
    static let shells: Set<String> = ["sh", "bash", "zsh", "dash", "ksh", "fish"]

    /// How many shells deep to look for the command, as in `( time npm test )`, which runs in a subshell.
    static let maxShellDepth = 4

    struct Scan: Equatable {
        var jobs: [BackgroundJob] = []
        /// When a process that was too young to count becomes old enough, so it's worth looking again.
        var recheckDate: Date?
    }

    /// The jobs of the agent whose process group is `agentGroup`, oldest first: processes whose parent is in
    /// that group but which run in a group of their own. `arguments` reads a process's arguments.
    static func scan(
        agentGroup: Int32,
        in processes: [RunningProcess],
        now: Date,
        arguments: (Int32) -> [String]?
    ) -> Scan {
        let members = Set(processes.lazy.filter { $0.groupId == agentGroup }.map(\.pid))
        let candidates = processes
            .filter { members.contains($0.parentPid) && $0.groupId != agentGroup && !$0.isZombie }
            .sorted(by: startedEarlier)

        var scan = Scan()
        for candidate in candidates {
            let oldEnough = candidate.startDate.addingTimeInterval(minimumAge)
            guard oldEnough <= now else {
                scan.recheckDate = min(scan.recheckDate ?? oldEnough, oldEnough)
                continue
            }
            let command = command(ofJob: candidate, in: processes, arguments: arguments)
            scan.jobs.append(BackgroundJob(pid: candidate.pid, command: command, startDate: candidate.startDate))
        }
        return scan
    }

    /// What a job runs. The job is a shell running a long script, so look under it, and under any subshell,
    /// for the first process that isn't a shell. A shell that hasn't started anything shows as its name.
    private static func command(ofJob job: RunningProcess, in processes: [RunningProcess], arguments: (Int32) -> [String]?) -> String {
        var current = job
        var argv = arguments(job.pid)
        for _ in 0..<maxShellDepth {
            guard isShell(argv),
                  let child = processes.filter({ $0.parentPid == current.pid && !$0.isZombie }).min(by: startedEarlier)
            else { break }
            current = child
            argv = arguments(child.pid)
        }
        guard let argv else { return command(from: []) }
        return isShell(argv) ? command(from: Array(argv.prefix(1))) : command(from: argv)
    }

    private static func isShell(_ argv: [String]?) -> Bool {
        guard let first = argv?.first else { return false }
        // A login shell's name starts with "-", as in "-zsh".
        let name = lastComponent(of: first)
        return shells.contains(name.hasPrefix("-") ? String(name.dropFirst()) : name)
    }

    /// A short command line for display, such as "npm test". Paths are shortened to their last component,
    /// an interpreter running a script by its path is left out, and a whole script passed as one argument,
    /// as in `zsh -c "…"`, shows as "…".
    static func command(from argv: [String]) -> String {
        var words = argv
        if words.count > 1, words[1].hasPrefix("/"), isInterpreter(lastComponent(of: words[0])) {
            words.removeFirst()
        }
        let line = words
            .map { word in
                if word.contains(where: \.isWhitespace) { return "…" }
                if word.contains("/"), !word.hasPrefix("-") { return lastComponent(of: word) }
                return word
            }
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !line.isEmpty else { return "unknown command" }
        guard line.count > maxCommandLength else { return line }
        return line.prefix(maxCommandLength - 1) + "…"
    }

    /// How long a job has been running, such as "45s", "12m" or "1h 5m".
    static func duration(from start: Date, to now: Date) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(start)))
        if seconds < 60 { return "\(seconds)s" }
        let minutes = seconds / 60
        if minutes < 60 { return "\(minutes)m" }
        let rest = minutes % 60
        return rest == 0 ? "\(minutes / 60)h" : "\(minutes / 60)h \(rest)m"
    }

    private static func startedEarlier(_ a: RunningProcess, _ b: RunningProcess) -> Bool {
        (a.startDate, a.pid) < (b.startDate, b.pid)
    }

    private static func isInterpreter(_ name: String) -> Bool {
        let name = name.lowercased()
        return interpreters.contains(name) || name.hasPrefix("python")
    }

    private static func lastComponent(of path: String) -> String {
        path.split(separator: "/").last.map(String.init) ?? path
    }
}
