import Testing
@testable import ProcLensCore

@Suite struct DiskCollectorTests {
    let t0 = ContinuousClock.now

    func d(_ id: String, _ r: UInt64, _ w: UInt64) -> BlockDeviceCounters {
        BlockDeviceCounters(id: id, bytesRead: r, bytesWritten: w)
    }

    @Test func firstSampleIsZero() async throws {
        let c = DiskCollector(source: MockIORegistrySource(blocks: [[d("1", 1000, 2000)]]))
        let s = try await c.sample(at: t0)
        #expect(s.readPerSec == 0 && s.writePerSec == 0)
    }

    @Test func deltaMathAcrossDevices() async throws {
        let c = DiskCollector(source: MockIORegistrySource(blocks: [
            [d("1", 1000, 0), d("2", 0, 500)],
            [d("1", 3000, 100), d("2", 1000, 1500)],
        ]))
        _ = try await c.sample(at: t0)
        let s = try await c.sample(at: t0.advanced(by: .seconds(2)))
        #expect(s.readPerSec == 1500)   // (2000 + 1000) / 2
        #expect(s.writePerSec == 550)   // (100 + 1000) / 2
    }

    @Test func counterDecreaseIsZeroForThatDevice() async throws {
        let c = DiskCollector(source: MockIORegistrySource(blocks: [
            [d("1", 5000, 5000), d("2", 0, 0)],
            [d("1", 100, 100), d("2", 400, 0)],
        ]))
        _ = try await c.sample(at: t0)
        let s = try await c.sample(at: t0.advanced(by: .seconds(1)))
        #expect(s.readPerSec == 400)
        #expect(s.writePerSec == 0)
    }

    @Test func newDeviceContributesZeroThenCounts() async throws {
        let c = DiskCollector(source: MockIORegistrySource(blocks: [
            [d("1", 0, 0)],
            [d("1", 100, 0), d("2", 9_000_000, 0)],
            [d("1", 200, 0), d("2", 9_000_300, 0)],
        ]))
        _ = try await c.sample(at: t0)
        #expect(try await c.sample(at: t0.advanced(by: .seconds(1))).readPerSec == 100)
        #expect(try await c.sample(at: t0.advanced(by: .seconds(2))).readPerSec == 400)
    }

    @Test func vanishedDeviceIsPrunedAndReappearsAsNew() async throws {
        let c = DiskCollector(source: MockIORegistrySource(blocks: [
            [d("1", 0, 0), d("2", 0, 0)],
            [d("1", 100, 0)],
            [d("1", 200, 0), d("2", 5000, 0)],
        ]))
        _ = try await c.sample(at: t0)
        #expect(try await c.sample(at: t0.advanced(by: .seconds(1))).readPerSec == 100)
        #expect(try await c.sample(at: t0.advanced(by: .seconds(2))).readPerSec == 100)
    }

    @Test func resetClearsState() async throws {
        let c = DiskCollector(source: MockIORegistrySource(blocks: [[d("1", 0, 0)], [d("1", 1000, 0)]]))
        _ = try await c.sample(at: t0)
        await c.reset()
        #expect(try await c.sample(at: t0.advanced(by: .seconds(1))).readPerSec == 0)
    }
}
