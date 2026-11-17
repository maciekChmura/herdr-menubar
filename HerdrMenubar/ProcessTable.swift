import Darwin
import Foundation

/// Where `AgentStore` reads processes from. Tests pass a made-up table.
struct ProcessSource: Sendable {
    /// Every process, or none if the table can't be read.
    var list: @Sendable () -> [RunningProcess]
    /// A process's arguments, starting with the name it was started with, or nil if they can't be read.
    var arguments: @Sendable (Int32) -> [String]?

    static let system = ProcessSource(list: ProcessTable.all, arguments: ProcessTable.arguments(of:))
}

/// Reads the system's process table through `sysctl`. The app isn't sandboxed, so it can read the
/// processes of its own user, which is all it needs.
enum ProcessTable {
    static func all() -> [RunningProcess] {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL]
        let stride = MemoryLayout<kinfo_proc>.stride
        // Processes can start between asking for the size and reading the table, so leave room and retry.
        for _ in 0..<3 {
            var size = 0
            guard sysctl(&mib, u_int(mib.count), nil, &size, nil, 0) == 0 else { return [] }
            var processes = [kinfo_proc](repeating: kinfo_proc(), count: size / stride + 16)
            size = processes.count * stride
            if sysctl(&mib, u_int(mib.count), &processes, &size, nil, 0) == 0 {
                return processes.prefix(size / stride).map(RunningProcess.init)
            }
            guard errno == ENOMEM else { return [] }
        }
        return []
    }

    static func arguments(of pid: Int32) -> [String]? {
        var argMax: Int32 = 0
        var argMaxSize = MemoryLayout<Int32>.size
        var argMaxMib: [Int32] = [CTL_KERN, KERN_ARGMAX]
        guard sysctl(&argMaxMib, 2, &argMax, &argMaxSize, nil, 0) == 0, argMax > 0 else { return nil }

        var buffer = [UInt8](repeating: 0, count: Int(argMax))
        var size = buffer.count
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0 else { return nil }
        return parseProcArgs(buffer.prefix(size))
    }

    /// Reads `KERN_PROCARGS2` output: the argument count, the executable's path, padding, then the
    /// arguments, each ending with a zero byte. The environment follows, and is left alone.
    static func parseProcArgs(_ bytes: ArraySlice<UInt8>) -> [String]? {
        let countSize = MemoryLayout<Int32>.size
        guard bytes.count > countSize else { return nil }
        let argc = bytes.prefix(countSize).withUnsafeBytes { $0.loadUnaligned(as: Int32.self) }
        var index = bytes.startIndex + countSize
        // Skip the executable's path, then the zero bytes after it.
        while index < bytes.endIndex, bytes[index] != 0 { index += 1 }
        while index < bytes.endIndex, bytes[index] == 0 { index += 1 }

        var arguments: [String] = []
        while arguments.count < argc, index < bytes.endIndex {
            let start = index
            while index < bytes.endIndex, bytes[index] != 0 { index += 1 }
            arguments.append(String(decoding: bytes[start..<index], as: UTF8.self))
            index += 1
        }
        return arguments
    }
}

extension RunningProcess {
    init(_ info: kinfo_proc) {
        let start = info.kp_proc.p_un.__p_starttime
        self.init(
            pid: info.kp_proc.p_pid,
            parentPid: info.kp_eproc.e_ppid,
            groupId: info.kp_eproc.e_pgid,
            startDate: Date(timeIntervalSince1970: TimeInterval(start.tv_sec) + TimeInterval(start.tv_usec) / 1_000_000),
            isZombie: Int32(info.kp_proc.p_stat) == SZOMB
        )
    }
}
