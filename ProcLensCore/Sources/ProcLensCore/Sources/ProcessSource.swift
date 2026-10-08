import Darwin

/// Static-ish per-process facts from `PROC_PIDTASKALLINFO` (`proc_bsdinfo` + `proc_taskinfo`).
public struct TaskAllInfo: Sendable, Hashable {
    public var pid: pid_t
    public var ppid: pid_t
    public var uid: uid_t
    /// `pbi_comm` / `pbi_name` (short name, may be truncated).
    public var name: String
    /// Microseconds since the Unix epoch.
    public var startTime: UInt64
    public var flags: UInt32
    public var status: UInt32
    public var threadCount: Int32
    /// True when `P_TRANSLATED` is set (Rosetta).
    public var isTranslated: Bool

    public init(pid: pid_t, ppid: pid_t, uid: uid_t, name: String, startTime: UInt64, flags: UInt32,
                status: UInt32, threadCount: Int32, isTranslated: Bool) {
        self.pid = pid
        self.ppid = ppid
        self.uid = uid
        self.name = name
        self.startTime = startTime
        self.flags = flags
        self.status = status
        self.threadCount = threadCount
        self.isTranslated = isTranslated
    }

    public var processID: ProcessID { ProcessID(pid: pid, startTime: startTime) }
}

/// Cumulative counters from `proc_pid_rusage(RUSAGE_INFO_V6)`. Times are nanoseconds.
public struct ResourceUsage: Sendable, Hashable {
    public var userTime: UInt64
    public var systemTime: UInt64
    public var physFootprint: UInt64
    public var diskBytesRead: UInt64
    public var diskBytesWritten: UInt64
    public var billedEnergy: UInt64
    public var interruptWakeups: UInt64
    public var packageIdleWakeups: UInt64
    /// `ri_proc_start_abstime`: process start in mach absolute time. Identity check for pid reuse
    /// without a second syscall (a changed value means a different process).
    public var startAbsTime: UInt64

    public init(userTime: UInt64, systemTime: UInt64, physFootprint: UInt64, diskBytesRead: UInt64,
                diskBytesWritten: UInt64, billedEnergy: UInt64, interruptWakeups: UInt64, packageIdleWakeups: UInt64,
                startAbsTime: UInt64 = 0) {
        self.userTime = userTime
        self.systemTime = systemTime
        self.physFootprint = physFootprint
        self.diskBytesRead = diskBytesRead
        self.diskBytesWritten = diskBytesWritten
        self.billedEnergy = billedEnergy
        self.interruptWakeups = interruptWakeups
        self.packageIdleWakeups = packageIdleWakeups
        self.startAbsTime = startAbsTime
    }
}

/// Cheap identity probe (`PROC_PIDT_SHORTBSDINFO`), readable for other users' processes.
public struct ShortInfo: Sendable, Hashable {
    public var ppid: pid_t
    public var uid: uid_t
    public var name: String
    public init(ppid: pid_t, uid: uid_t, name: String) {
        self.ppid = ppid
        self.uid = uid
        self.name = name
    }
}

/// Per-process syscalls (libproc + sysctl). Every call may throw `ESRCH` (gone) or `EPERM`.
public protocol ProcessSource: Sendable {
    func allPIDs() throws -> [pid_t]
    func taskAllInfo(_ pid: pid_t) throws -> TaskAllInfo
    func rusage(_ pid: pid_t) throws -> ResourceUsage
    func path(_ pid: pid_t) throws -> String
    /// Raw `KERN_PROCARGS2` buffer; parse with `ProcArgsParser`.
    func procArgs(_ pid: pid_t) throws -> [UInt8]

    /// Fills `buffer` with all pids (kernel_task once), reusing its storage across ticks.
    func allPIDs(into buffer: inout [pid_t]) throws
    /// One cheap call: the current thread count only (refreshed every few ticks).
    func threadCount(_ pid: pid_t) throws -> Int32
    /// One cheap call: ppid/uid/name, used to re-validate pids that cannot be sampled.
    func shortInfo(_ pid: pid_t) throws -> ShortInfo
}

extension ProcessSource {
    public func allPIDs(into buffer: inout [pid_t]) throws { buffer = try allPIDs() }
    public func threadCount(_ pid: pid_t) throws -> Int32 { try taskAllInfo(pid).threadCount }
    public func shortInfo(_ pid: pid_t) throws -> ShortInfo {
        let i = try taskAllInfo(pid)
        return ShortInfo(ppid: i.ppid, uid: i.uid, name: i.name)
    }
}

public struct SourceError: Error, Sendable, Hashable {
    public let call: String
    public let errno: Int32
    public init(_ call: String, errno: Int32) {
        self.call = call
        self.errno = errno
    }
    public var isGone: Bool { errno == ESRCH }
    public var isDenied: Bool { errno == EPERM || errno == EACCES }
}
