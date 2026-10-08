// Adapted from exelban/stats@ee4265f3, Modules/Net/readers.swift (getBytesInfo: NET_RT_IFLIST2 byte counters)
// Copyright (c) 2019 Serhiy Mytrovtsiy, MIT License (see THIRD_PARTY_NOTICES.md)

/// Per-interface network throughput: counter deltas divided by elapsed time. Loopback is excluded.
public actor NetworkCollector: Collector {
    public typealias Sample = NetworkSample

    public nonisolated let id = CollectorID("network")
    public nonisolated let cost = CollectorCost.perTick

    private let source: any NetworkSource
    private var previous: [String: InterfaceCounters] = [:]
    private var previousInstant: ContinuousClock.Instant?

    public init(source: any NetworkSource) {
        self.source = source
    }

    public func sample(at instant: ContinuousClock.Instant) async throws -> NetworkSample {
        let interfaces = try source.interfaces().filter { !$0.isLoopback }
        let last = previous
        let lastInstant = previousInstant
        // Replacing the dictionary also prunes interfaces that vanished.
        previous = Dictionary(interfaces.map { ($0.name, $0) }, uniquingKeysWith: { _, new in new })
        previousInstant = instant

        let elapsed = lastInstant.map { DiskCollector.seconds(instant - $0) } ?? 0
        let samples = interfaces.map { cur -> NetworkInterfaceSample in
            // First sample, new interface, or counter went backwards: zero for this tick.
            guard elapsed > 0, let old = last[cur.name], cur.bytesIn >= old.bytesIn, cur.bytesOut >= old.bytesOut else {
                return NetworkInterfaceSample(name: cur.name, receivedPerSec: 0, sentPerSec: 0)
            }
            return NetworkInterfaceSample(name: cur.name,
                                          receivedPerSec: Double(cur.bytesIn - old.bytesIn) / elapsed,
                                          sentPerSec: Double(cur.bytesOut - old.bytesOut) / elapsed)
        }
        return NetworkSample(interfaces: samples)
    }

    public func reset() {
        previous = [:]
        previousInstant = nil
    }
}
