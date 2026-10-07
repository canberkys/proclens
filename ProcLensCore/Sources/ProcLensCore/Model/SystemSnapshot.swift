/// Everything the Sampler collected in one tick. Fields are optional because
/// collectors run at different cadences or may fail independently.
public struct SystemSnapshot: Sendable {
    public let tick: UInt64
    public let instant: ContinuousClock.Instant
    public var cpu: CPUSample?
    public var memory: MemorySample?
    public var processes: ProcessTable?

    public init(tick: UInt64, instant: ContinuousClock.Instant, cpu: CPUSample? = nil, memory: MemorySample? = nil,
                processes: ProcessTable? = nil) {
        self.tick = tick
        self.instant = instant
        self.cpu = cpu
        self.memory = memory
        self.processes = processes
    }
}

public enum CoreKind: String, Sendable, Codable {
    case performance, efficiency, unknown
}

public struct CPUCoreSample: Sendable, Hashable {
    public let index: Int
    public let kind: CoreKind
    /// 0...1
    public let user: Double
    public let system: Double

    public init(index: Int, kind: CoreKind, user: Double, system: Double) {
        self.index = index
        self.kind = kind
        self.user = user
        self.system = system
    }

    public var total: Double { user + system }
}

public struct CPUSample: Sendable, Hashable {
    public let cores: [CPUCoreSample]
    public init(cores: [CPUCoreSample]) { self.cores = cores }

    public var total: Double {
        cores.isEmpty ? 0 : cores.reduce(0) { $0 + $1.total } / Double(cores.count)
    }
}

public enum MemoryPressure: String, Sendable, Codable {
    case normal, warning, critical
}

public struct MemorySample: Sendable, Hashable {
    public let total: UInt64
    public let app: UInt64
    public let wired: UInt64
    public let compressed: UInt64
    public let cached: UInt64
    public let swapUsed: UInt64
    public let pressure: MemoryPressure

    public init(total: UInt64, app: UInt64, wired: UInt64, compressed: UInt64, cached: UInt64, swapUsed: UInt64, pressure: MemoryPressure) {
        self.total = total
        self.app = app
        self.wired = wired
        self.compressed = compressed
        self.cached = cached
        self.swapUsed = swapUsed
        self.pressure = pressure
    }

    public var used: UInt64 { app + wired + compressed }
}
