/// Cumulative byte counters for one block storage driver (IOBlockStorageDriver `Statistics`).
public struct BlockDeviceCounters: Sendable, Hashable {
    public let id: String
    public let bytesRead: UInt64
    public let bytesWritten: UInt64
    public init(id: String, bytesRead: UInt64, bytesWritten: UInt64) {
        self.id = id
        self.bytesRead = bytesRead
        self.bytesWritten = bytesWritten
    }
}

/// Cumulative byte counters for one network interface (`NET_RT_IFLIST2` / `if_msghdr2`).
public struct InterfaceCounters: Sendable, Hashable {
    public let name: String
    public let bytesIn: UInt64
    public let bytesOut: UInt64
    public let isLoopback: Bool
    public init(name: String, bytesIn: UInt64, bytesOut: UInt64, isLoopback: Bool) {
        self.name = name
        self.bytesIn = bytesIn
        self.bytesOut = bytesOut
        self.isLoopback = isLoopback
    }
}

/// IOKit registry reads (public IOKit API; property keys are not formally documented).
public protocol IORegistrySource: Sendable {
    func gpuDevices() throws -> [GPUDeviceSample]
    func blockDevices() throws -> [BlockDeviceCounters]
}

public protocol NetworkSource: Sendable {
    func interfaces() throws -> [InterfaceCounters]
}
