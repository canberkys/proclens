/// One GPU from IOAccelerator `PerformanceStatistics`.
public struct GPUDeviceSample: Sendable, Hashable {
    public let name: String
    /// 0...1
    public let utilization: Double
    public init(name: String, utilization: Double) {
        self.name = name
        self.utilization = utilization
    }
}

public struct GPUSample: Sendable, Hashable {
    public let devices: [GPUDeviceSample]
    public init(devices: [GPUDeviceSample]) { self.devices = devices }
    public var utilization: Double { devices.map(\.utilization).max() ?? 0 }
}

/// Aggregate disk throughput across physical block devices, bytes per second.
public struct DiskSample: Sendable, Hashable {
    public let readPerSec: Double
    public let writePerSec: Double
    public init(readPerSec: Double, writePerSec: Double) {
        self.readPerSec = readPerSec
        self.writePerSec = writePerSec
    }
}

public struct NetworkInterfaceSample: Sendable, Hashable {
    public let name: String
    public let receivedPerSec: Double
    public let sentPerSec: Double
    public init(name: String, receivedPerSec: Double, sentPerSec: Double) {
        self.name = name
        self.receivedPerSec = receivedPerSec
        self.sentPerSec = sentPerSec
    }
}

public struct NetworkSample: Sendable, Hashable {
    public let interfaces: [NetworkInterfaceSample]
    public init(interfaces: [NetworkInterfaceSample]) { self.interfaces = interfaces }
    /// Tunnel interfaces carry traffic that also crosses a physical interface (VPN),
    /// so they are excluded from the totals to avoid double counting.
    public static let tunnelPrefixes = ["utun", "ipsec", "gif", "stf", "ppp"]

    public var physicalInterfaces: [NetworkInterfaceSample] {
        interfaces.filter { i in !Self.tunnelPrefixes.contains { i.name.hasPrefix($0) } }
    }

    public var receivedPerSec: Double { physicalInterfaces.reduce(0) { $0 + $1.receivedPerSec } }
    public var sentPerSec: Double { physicalInterfaces.reduce(0) { $0 + $1.sentPerSec } }
}
