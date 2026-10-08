import Darwin

/// One process in one tick. Rates are computed from the previous tick's counters.
public struct ProcessSample: Sendable, Hashable, Identifiable {
    public let id: ProcessID
    public var ppid: pid_t
    public var uid: uid_t
    public var name: String
    public var path: String?
    public var threadCount: Int32
    public var isTranslated: Bool
    /// 0...n (1.0 = one full core), like Activity Monitor's % / 100.
    public var cpu: Double
    public var memory: UInt64
    public var diskReadPerSec: Double
    public var diskWritePerSec: Double
    /// Approximate energy score (D1); not identical to Activity Monitor.
    public var energy: Double
    /// True when some fields could not be read (`EPERM`).
    public var isRestricted: Bool
    /// True when the values come from the privileged helper (the process is not readable by this app).
    /// Such a process has `isRestricted == false` but still cannot be inspected directly (argv, fds, ...).
    public var viaHelper: Bool

    public init(id: ProcessID, ppid: pid_t, uid: uid_t, name: String, path: String?, threadCount: Int32,
                isTranslated: Bool, cpu: Double, memory: UInt64, diskReadPerSec: Double, diskWritePerSec: Double,
                energy: Double, isRestricted: Bool, viaHelper: Bool = false) {
        self.id = id
        self.ppid = ppid
        self.uid = uid
        self.name = name
        self.path = path
        self.threadCount = threadCount
        self.isTranslated = isTranslated
        self.cpu = cpu
        self.memory = memory
        self.diskReadPerSec = diskReadPerSec
        self.diskWritePerSec = diskWritePerSec
        self.energy = energy
        self.isRestricted = isRestricted
        self.viaHelper = viaHelper
    }

    public var pid: pid_t { id.pid }
}

public struct ProcessTable: Sendable {
    public var processes: [ProcessID: ProcessSample]
    public init(processes: [ProcessID: ProcessSample]) { self.processes = processes }
}
