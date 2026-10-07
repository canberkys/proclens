// Adapted from exelban/stats@ee4265f3, Modules/Disk/readers.swift (ActivityReader: IOBlockStorageDriver Statistics byte counters)
// Copyright (c) 2019 Serhiy Mytrovtsiy, MIT License (see THIRD_PARTY_NOTICES.md)

/// Aggregate disk throughput: per-device counter deltas divided by elapsed time, summed.
public actor DiskCollector: Collector {
    public typealias Sample = DiskSample

    public nonisolated let id = CollectorID("disk")
    public nonisolated let cost = CollectorCost.perTick

    private let source: any IORegistrySource
    private var previous: [String: BlockDeviceCounters] = [:]
    private var previousInstant: ContinuousClock.Instant?

    public init(source: any IORegistrySource) {
        self.source = source
    }

    public func sample(at instant: ContinuousClock.Instant) async throws -> DiskSample {
        let devices = try source.blockDevices()
        let last = previous
        let lastInstant = previousInstant
        // Replacing the dictionary also prunes devices that vanished.
        previous = Dictionary(devices.map { ($0.id, $0) }, uniquingKeysWith: { _, new in new })
        previousInstant = instant

        guard let lastInstant else { return DiskSample(readPerSec: 0, writePerSec: 0) }
        let elapsed = Self.seconds(instant - lastInstant)
        guard elapsed > 0 else { return DiskSample(readPerSec: 0, writePerSec: 0) }

        var read: UInt64 = 0, written: UInt64 = 0
        for device in previous.values {
            // New device or counter went backwards (reset): contributes zero this tick.
            guard let old = last[device.id], device.bytesRead >= old.bytesRead, device.bytesWritten >= old.bytesWritten else { continue }
            read &+= device.bytesRead - old.bytesRead
            written &+= device.bytesWritten - old.bytesWritten
        }
        return DiskSample(readPerSec: Double(read) / elapsed, writePerSec: Double(written) / elapsed)
    }

    public func reset() {
        previous = [:]
        previousInstant = nil
    }

    static func seconds(_ d: Duration) -> Double {
        Double(d.components.seconds) + Double(d.components.attoseconds) / 1e18
    }
}
