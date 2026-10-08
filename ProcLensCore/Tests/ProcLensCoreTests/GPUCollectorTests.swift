import Testing
@testable import ProcLensCore

@Suite struct GPUCollectorTests {
    @Test func passesThroughDevices() async throws {
        let c = GPUCollector(source: MockIORegistrySource(gpu: [[GPUDeviceSample(name: "A", utilization: 0.25),
                                                                  GPUDeviceSample(name: "B", utilization: 0.75)]]))
        let s = try await c.sample(at: .now)
        #expect(s.devices.map(\.name) == ["A", "B"])
        #expect(s.utilization == 0.75)
        #expect(c.id.rawValue == "gpu")
        #expect(c.cost == .perTick)
    }

    @Test func noDevicesIsZero() async throws {
        let s = try await GPUCollector(source: MockIORegistrySource()).sample(at: .now)
        #expect(s.devices.isEmpty)
        #expect(s.utilization == 0)
    }
}
