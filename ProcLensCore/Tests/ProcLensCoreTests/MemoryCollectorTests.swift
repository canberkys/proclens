import Testing
@testable import ProcLensCore

@Suite struct MemoryCollectorTests {
    func vm(internal i: UInt64, purgeable p: UInt64) -> VMStats {
        VMStats(physicalMemory: 16_000, free: 1, active: 2, inactive: 3, speculative: 4,
                wired: 300, compressed: 200, purgeable: p, external: 500, internal: i, swapUsed: 77)
    }

    @Test func formula() async throws {
        let c = MemoryCollector(source: MockHostSource(vm: vm(internal: 1000, purgeable: 100), pressure: .warning))
        let s = try await c.sample(at: .now)
        #expect(s.total == 16_000)
        #expect(s.app == 900)
        #expect(s.wired == 300)
        #expect(s.compressed == 200)
        #expect(s.cached == 600)
        #expect(s.swapUsed == 77)
        #expect(s.pressure == .warning)
        #expect(s.used == 1400)
    }

    @Test func appClampedAtZero() async throws {
        let c = MemoryCollector(source: MockHostSource(vm: vm(internal: 50, purgeable: 100)))
        #expect(try await c.sample(at: .now).app == 0)
    }

    @Test func identity() async {
        let c = MemoryCollector(source: MockHostSource())
        #expect(c.id == CollectorID("memory"))
        #expect(c.cost == .perTick)
    }
}
