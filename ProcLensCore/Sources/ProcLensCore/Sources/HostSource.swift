/// Raw cumulative CPU ticks for one logical core (from `host_processor_info`).
public struct CoreTicks: Sendable, Hashable {
    public var user: UInt64
    public var system: UInt64
    public var idle: UInt64
    public var nice: UInt64

    public init(user: UInt64, system: UInt64, idle: UInt64, nice: UInt64) {
        self.user = user
        self.system = system
        self.idle = idle
        self.nice = nice
    }
}

/// One `hw.perflevelN` entry. perflevel0 is the highest-performance level.
public struct PerfLevel: Sendable, Hashable {
    public let level: Int
    public let name: String
    public let logicalCPUCount: Int

    public init(level: Int, name: String, logicalCPUCount: Int) {
        self.level = level
        self.name = name
        self.logicalCPUCount = logicalCPUCount
    }
}

/// Host-wide syscalls (Mach host + sysctl). Live implementation lands in Phase 1 step 2.
public protocol HostSource: Sendable {
    func cpuTicks() throws -> [CoreTicks]
    func perfLevels() throws -> [PerfLevel]
}
