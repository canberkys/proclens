// Adapted from exelban/stats@ee4265f3, Modules/CPU/readers.swift (LoadReader.read: per-core tick deltas)
// Copyright (c) 2019 Serhiy Mytrovtsiy, MIT License (see THIRD_PARTY_NOTICES.md)

/// Per-core CPU usage from `host_processor_info` tick deltas.
public actor CPUCollector: Collector {
    public typealias Sample = CPUSample

    public nonisolated let id = CollectorID("cpu")
    public nonisolated let cost = CollectorCost.perTick

    private let source: any HostSource
    private var previous: [CoreTicks]?
    /// Read once, lazily. Keyed by core count so a count change recomputes it.
    private var kinds: [CoreKind]?

    public init(source: any HostSource) {
        self.source = source
    }

    public func sample(at instant: ContinuousClock.Instant) async throws -> CPUSample {
        let ticks = try source.cpuTicks()
        let kinds = coreKinds(count: ticks.count)
        defer { previous = ticks }

        // First sample, or the core count changed (hotplug / sleep quirks): no usable delta.
        guard let previous, previous.count == ticks.count else {
            return CPUSample(cores: ticks.indices.map { CPUCoreSample(index: $0, kind: kinds[$0], user: 0, system: 0) })
        }

        let cores = ticks.indices.map { i -> CPUCoreSample in
            let cur = ticks[i], prev = previous[i]
            // host_processor_info ticks are 32-bit counters that wrap; subtract in UInt32 space.
            func delta(_ a: UInt64, _ b: UInt64) -> UInt64 { UInt64(UInt32(truncatingIfNeeded: a) &- UInt32(truncatingIfNeeded: b)) }
            let user = delta(cur.user, prev.user)
            let nice = delta(cur.nice, prev.nice)
            let system = delta(cur.system, prev.system)
            let idle = delta(cur.idle, prev.idle)
            let total = user + nice + system + idle
            guard total > 0 else { return CPUCoreSample(index: i, kind: kinds[i], user: 0, system: 0) }
            return CPUCoreSample(index: i, kind: kinds[i],
                                 user: min(1, Double(user + nice) / Double(total)),
                                 system: min(1, Double(system) / Double(total)))
        }
        return CPUSample(cores: cores)
    }

    public func reset() {
        previous = nil
    }

    /// Core-ordering decision (verified on an M-series Mac with 4E + 10P; IORegistry `cpuN`
    /// `cluster-type` is E for cpu0-3 and P for cpu4-13, and stats reads that same per-cpu order):
    /// logical CPU indices run LEAST performant first. `hw.perflevel0` is the highest level
    /// (Performance), so we walk the levels from the highest index (Efficiency) down to 0 and
    /// assign contiguous index ranges. If the counts don't add up to the real core count
    /// (Intel, or an unexpected topology) every core is `.unknown`.
    private func coreKinds(count: Int) -> [CoreKind] {
        if let kinds, kinds.count == count { return kinds }
        let levels = ((try? source.perfLevels()) ?? []).sorted { $0.level > $1.level }
        var result: [CoreKind] = []
        for level in levels {
            let name = level.name.lowercased()
            let kind: CoreKind = name.contains("eff") ? .efficiency
                : (name.contains("perf") || name.contains("super")) ? .performance : .unknown
            result += Array(repeating: kind, count: max(0, level.logicalCPUCount))
        }
        if result.count != count { result = Array(repeating: .unknown, count: count) }
        kinds = result
        return result
    }
}
