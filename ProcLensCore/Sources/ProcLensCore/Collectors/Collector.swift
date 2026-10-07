/// Identifies a collector in logs, the Sampler schedule and self-overhead accounting.
public struct CollectorID: Hashable, Sendable, CustomStringConvertible {
    public let rawValue: String
    public init(_ rawValue: String) { self.rawValue = rawValue }
    public var description: String { rawValue }
}

/// How often the Sampler runs a collector.
public enum CollectorCost: Hashable, Sendable {
    /// Every tick (cheap: host stats, process table).
    case perTick
    /// Every n-th tick (moderately expensive: per-process sockets).
    case everyN(Int)
    /// Never scheduled; called explicitly (inspector, signatures, dylibs).
    case onDemand
}

/// One collector produces one kind of sample per tick.
///
/// Collectors are actors: they keep their previous raw reading to compute deltas
/// and are never touched from the main thread. They read the system only through
/// an injected `Sendable` source protocol so tests can mock every syscall.
public protocol Collector<Sample>: Actor {
    associatedtype Sample: Sendable

    nonisolated var id: CollectorID { get }
    nonisolated var cost: CollectorCost { get }

    /// Takes one reading. `instant` is the tick time, used for rate computation.
    func sample(at instant: ContinuousClock.Instant) async throws -> Sample

    /// Drops delta state (e.g. after the sampling interval changes).
    func reset()
}
