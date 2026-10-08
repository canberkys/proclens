// Adapted from exelban/stats@ee4265f3, Modules/RAM/readers.swift (UsageReader.read)
// Copyright (c) 2019 Serhiy Mytrovtsiy, MIT License (see THIRD_PARTY_NOTICES.md)

/// Activity-Monitor-like memory composition plus pressure.
public actor MemoryCollector: Collector {
    public typealias Sample = MemorySample

    public nonisolated let id = CollectorID("memory")
    public nonisolated let cost = CollectorCost.perTick

    private let source: any HostSource

    public init(source: any HostSource) {
        self.source = source
    }

    public func sample(at instant: ContinuousClock.Instant) async throws -> MemorySample {
        let vm = try source.vmStats()
        let pressure = (try? source.memoryPressure()) ?? .normal
        // Formula (Activity Monitor's categories, as reproduced by stats' UsageReader):
        //   App Memory = internal pages - purgeable pages (clamped at 0)
        //   Cached     = external (file-backed) pages + purgeable pages
        //   Wired, Compressed straight from vm_statistics64.
        return MemorySample(
            total: vm.physicalMemory,
            app: vm.internal > vm.purgeable ? vm.internal - vm.purgeable : 0,
            wired: vm.wired,
            compressed: vm.compressed,
            cached: vm.external + vm.purgeable,
            swapUsed: vm.swapUsed,
            pressure: pressure
        )
    }

    public func reset() {}
}
