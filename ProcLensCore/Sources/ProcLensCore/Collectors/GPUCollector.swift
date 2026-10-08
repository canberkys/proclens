// Adapted from exelban/stats@ee4265f3, Modules/GPU/reader.swift (InfoReader.read: utilization from IOAccelerator PerformanceStatistics)
// Copyright (c) 2019 Serhiy Mytrovtsiy, MIT License (see THIRD_PARTY_NOTICES.md)

/// GPU utilization: a passthrough of the instantaneous IOAccelerator reading (no deltas needed).
public actor GPUCollector: Collector {
    public typealias Sample = GPUSample

    public nonisolated let id = CollectorID("gpu")
    public nonisolated let cost = CollectorCost.perTick

    private let source: any IORegistrySource

    public init(source: any IORegistrySource) {
        self.source = source
    }

    public func sample(at instant: ContinuousClock.Instant) async throws -> GPUSample {
        GPUSample(devices: try source.gpuDevices())
    }

    public func reset() {}
}
