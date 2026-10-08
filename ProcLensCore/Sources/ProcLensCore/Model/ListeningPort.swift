import Darwin

/// A listening TCP socket or bound (unconnected) UDP socket and its owner.
public struct ListeningPort: Sendable, Hashable, Identifiable {
    public enum TransportProtocol: String, Sendable, Hashable { case tcp, udp }

    public var port: UInt16
    public var proto: TransportProtocol
    /// Bind address text: `0.0.0.0`, `::`, `127.0.0.1`, `::1`, or a specific interface address.
    public var address: String
    public var isLoopbackOnly: Bool
    public var pid: pid_t
    public var processID: ProcessID

    public var id: String { "\(proto.rawValue):\(address):\(port):\(pid)" }

    public init(port: UInt16, proto: TransportProtocol, address: String, isLoopbackOnly: Bool, pid: pid_t,
                processID: ProcessID) {
        self.port = port
        self.proto = proto
        self.address = address
        self.isLoopbackOnly = isLoopbackOnly
        self.pid = pid
        self.processID = processID
    }
}
