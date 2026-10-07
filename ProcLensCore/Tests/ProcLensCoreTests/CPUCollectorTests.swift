import Testing
@testable import ProcLensCore

@Suite struct CPUCollectorTests {
    let now = ContinuousClock.now

    func t(_ u: UInt64, _ s: UInt64, _ i: UInt64, _ n: UInt64 = 0) -> CoreTicks {
        CoreTicks(user: u, system: s, idle: i, nice: n)
    }

    @Test func firstSampleIsZero() async throws {
        let c = CPUCollector(source: MockHostSource(ticks: [[t(10, 5, 85), t(1, 1, 1)]]))
        let s = try await c.sample(at: now)
        #expect(s.cores.count == 2)
        #expect(s.cores.allSatisfy { $0.user == 0 && $0.system == 0 })
        #expect(s.total == 0)
    }

    @Test func deltaMath() async throws {
        let c = CPUCollector(source: MockHostSource(ticks: [
            [t(0, 0, 0), t(0, 0, 0)],
            [t(20, 10, 70, 10), t(0, 0, 100)],
        ]))
        _ = try await c.sample(at: now)
        let s = try await c.sample(at: now)
        #expect(abs(s.cores[0].user - 30.0 / 110.0) < 1e-9)
        #expect(abs(s.cores[0].system - 10.0 / 110.0) < 1e-9)
        #expect(s.cores[1].total == 0)
    }

    @Test func zeroTotalDeltaIsZero() async throws {
        let same = [t(5, 5, 5)]
        let c = CPUCollector(source: MockHostSource(ticks: [same, same]))
        _ = try await c.sample(at: now)
        #expect(try await c.sample(at: now).cores[0].total == 0)
    }

    @Test func counterWrap() async throws {
        let c = CPUCollector(source: MockHostSource(ticks: [
            [t(UInt64(UInt32.max) - 4, 0, 0)],
            [t(5, 0, 10)],   // user wrapped: delta 10, idle 10
        ]))
        _ = try await c.sample(at: now)
        let s = try await c.sample(at: now)
        #expect(abs(s.cores[0].user - 0.5) < 1e-9)
    }

    @Test func coreCountChangeResets() async throws {
        let c = CPUCollector(source: MockHostSource(ticks: [
            [t(0, 0, 0), t(0, 0, 0)],
            [t(50, 0, 50), t(50, 0, 50), t(50, 0, 50)],
        ]))
        _ = try await c.sample(at: now)
        let s = try await c.sample(at: now)
        #expect(s.cores.count == 3)
        #expect(s.total == 0)
    }

    @Test func resetDropsPrevious() async throws {
        let c = CPUCollector(source: MockHostSource(ticks: [[t(0, 0, 0)], [t(50, 0, 50)]]))
        _ = try await c.sample(at: now)
        await c.reset()
        #expect(try await c.sample(at: now).total == 0)
    }

    @Test func kindsEfficiencyFirst() async throws {
        let levels = [PerfLevel(level: 0, name: "Performance", logicalCPUCount: 3),
                      PerfLevel(level: 1, name: "Efficiency", logicalCPUCount: 2)]
        let ticks = Array(repeating: t(0, 0, 0), count: 5)
        let c = CPUCollector(source: MockHostSource(ticks: [ticks], levels: levels))
        let kinds = try await c.sample(at: now).cores.map(\.kind)
        #expect(kinds == [.efficiency, .efficiency, .performance, .performance, .performance])
    }

    @Test func kindsUnknownWithoutLevelsOrMismatch() async throws {
        let ticks = Array(repeating: t(0, 0, 0), count: 4)
        let intel = CPUCollector(source: MockHostSource(ticks: [ticks]))
        #expect(try await intel.sample(at: now).cores.allSatisfy { $0.kind == .unknown })
        let bad = CPUCollector(source: MockHostSource(ticks: [ticks],
                    levels: [PerfLevel(level: 0, name: "Performance", logicalCPUCount: 9)]))
        #expect(try await bad.sample(at: now).cores.allSatisfy { $0.kind == .unknown })
    }

    @Test func identity() async {
        let c = CPUCollector(source: MockHostSource())
        #expect(c.id == CollectorID("cpu"))
        #expect(c.cost == .perTick)
    }
}
