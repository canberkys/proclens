import Testing
@testable import ProcLensCore

@Suite struct NetworkCollectorTests {
    let t0 = ContinuousClock.now

    func i(_ name: String, _ rx: UInt64, _ tx: UInt64, lo: Bool = false) -> InterfaceCounters {
        InterfaceCounters(name: name, bytesIn: rx, bytesOut: tx, isLoopback: lo)
    }

    @Test func firstSampleIsZero() async throws {
        let c = NetworkCollector(source: MockNetworkSource([[i("en0", 1000, 2000)]]))
        let s = try await c.sample(at: t0)
        #expect(s.interfaces.map(\.name) == ["en0"])
        #expect(s.receivedPerSec == 0 && s.sentPerSec == 0)
    }

    @Test func deltaMath() async throws {
        let c = NetworkCollector(source: MockNetworkSource([
            [i("en0", 1000, 0), i("en1", 0, 0)],
            [i("en0", 3000, 400), i("en1", 500, 100)],
        ]))
        _ = try await c.sample(at: t0)
        let s = try await c.sample(at: t0.advanced(by: .seconds(2)))
        #expect(s.interfaces[0].receivedPerSec == 1000)
        #expect(s.interfaces[0].sentPerSec == 200)
        #expect(s.receivedPerSec == 1250)
        #expect(s.sentPerSec == 250)
    }

    @Test func loopbackExcluded() async throws {
        let c = NetworkCollector(source: MockNetworkSource([
            [i("lo0", 0, 0, lo: true), i("en0", 0, 0)],
            [i("lo0", 9999, 9999, lo: true), i("en0", 100, 0)],
        ]))
        _ = try await c.sample(at: t0)
        let s = try await c.sample(at: t0.advanced(by: .seconds(1)))
        #expect(s.interfaces.map(\.name) == ["en0"])
        #expect(s.receivedPerSec == 100)
    }

    @Test func counterResetIsZero() async throws {
        let c = NetworkCollector(source: MockNetworkSource([[i("en0", 5000, 5000)], [i("en0", 10, 10)], [i("en0", 110, 10)]]))
        _ = try await c.sample(at: t0)
        let s = try await c.sample(at: t0.advanced(by: .seconds(1)))
        #expect(s.receivedPerSec == 0 && s.sentPerSec == 0)
        #expect(try await c.sample(at: t0.advanced(by: .seconds(2))).receivedPerSec == 100)
    }

    @Test func vanishedInterfaceDroppedAndReappearsAsNew() async throws {
        let c = NetworkCollector(source: MockNetworkSource([
            [i("en0", 0, 0), i("utun3", 0, 0)],
            [i("en0", 100, 0)],
            [i("en0", 200, 0), i("utun3", 7000, 0)],
        ]))
        _ = try await c.sample(at: t0)
        let s1 = try await c.sample(at: t0.advanced(by: .seconds(1)))
        #expect(s1.interfaces.map(\.name) == ["en0"])
        let s2 = try await c.sample(at: t0.advanced(by: .seconds(2)))
        #expect(s2.receivedPerSec == 100)
        #expect(s2.interfaces.first { $0.name == "utun3" }?.receivedPerSec == 0)
    }

    @Test func resetClearsState() async throws {
        let c = NetworkCollector(source: MockNetworkSource([[i("en0", 0, 0)], [i("en0", 1000, 0)]]))
        _ = try await c.sample(at: t0)
        await c.reset()
        #expect(try await c.sample(at: t0.advanced(by: .seconds(1))).receivedPerSec == 0)
    }
}

@Test func totalsExcludeTunnelInterfaces() {
    let s = NetworkSample(interfaces: [
        NetworkInterfaceSample(name: "en0", receivedPerSec: 100, sentPerSec: 10),
        NetworkInterfaceSample(name: "utun3", receivedPerSec: 90, sentPerSec: 9),
    ])
    #expect(s.receivedPerSec == 100)
    #expect(s.sentPerSec == 10)
}
