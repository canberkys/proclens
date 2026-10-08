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

/// Page counts from `host_statistics64(HOST_VM_INFO64)` plus related sysctls, in bytes.
public struct VMStats: Sendable, Hashable {
    public var physicalMemory: UInt64
    public var free: UInt64
    public var active: UInt64
    public var inactive: UInt64
    public var speculative: UInt64
    public var wired: UInt64
    public var compressed: UInt64
    public var purgeable: UInt64
    public var external: UInt64
    public var `internal`: UInt64
    public var swapUsed: UInt64

    public init(physicalMemory: UInt64, free: UInt64, active: UInt64, inactive: UInt64, speculative: UInt64,
                wired: UInt64, compressed: UInt64, purgeable: UInt64, external: UInt64, internal: UInt64, swapUsed: UInt64) {
        self.physicalMemory = physicalMemory
        self.free = free
        self.active = active
        self.inactive = inactive
        self.speculative = speculative
        self.wired = wired
        self.compressed = compressed
        self.purgeable = purgeable
        self.external = external
        self.internal = `internal`
        self.swapUsed = swapUsed
    }
}

/// Host-wide syscalls (Mach host + sysctl).
public protocol HostSource: Sendable {
    func cpuTicks() throws -> [CoreTicks]
    func perfLevels() throws -> [PerfLevel]
    func vmStats() throws -> VMStats
    /// `kern.memorystatus_vm_pressure_level`
    func memoryPressure() throws -> MemoryPressure
}
