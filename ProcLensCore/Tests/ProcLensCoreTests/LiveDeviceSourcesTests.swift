import Testing
@testable import ProcLensCore

@Suite struct LiveDeviceSourcesTests {
    @Test func blockDevicesNonEmpty() throws {
        let devices = try LiveIORegistrySource().blockDevices()
        print("[live] block devices: \(devices.count) \(devices)")
        #expect(!devices.isEmpty)
        #expect(devices.contains { $0.bytesRead > 0 })
    }

    @Test func gpuDevices() throws {
        let devices = try LiveIORegistrySource().gpuDevices()
        print("[live] gpu devices: \(devices)")
        #expect(!devices.isEmpty)
        for d in devices {
            #expect((0...1).contains(d.utilization))
            #expect(!d.name.isEmpty)
        }
    }

    @Test func interfacesContainLoopback() throws {
        let interfaces = try LiveNetworkSource().interfaces()
        print("[live] interfaces: \(interfaces.map(\.name))")
        let lo = interfaces.first { $0.name == "lo0" }
        #expect(lo?.isLoopback == true)
        #expect(interfaces.filter(\.isLoopback).allSatisfy { $0.name.hasPrefix("lo") })
        #expect(interfaces.contains { !$0.isLoopback })
    }

    @Test func repeatedReadsDoNotDecrease() throws {
        let source = LiveNetworkSource()
        let a = try source.interfaces(), b = try source.interfaces()
        for x in a { if let y = b.first(where: { $0.name == x.name }) { #expect(y.bytesIn >= x.bytesIn) } }
    }
}
