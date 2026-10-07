import Darwin

public enum TCPState: Int32, Sendable, Hashable {
    case closed = 0, listen, synSent, synReceived, established, closeWait, finWait1, closing, lastAck, finWait2, timeWait

    public var label: String {
        switch self {
        case .closed: "CLOSED"
        case .listen: "LISTEN"
        case .synSent: "SYN_SENT"
        case .synReceived: "SYN_RECEIVED"
        case .established: "ESTABLISHED"
        case .closeWait: "CLOSE_WAIT"
        case .finWait1: "FIN_WAIT_1"
        case .closing: "CLOSING"
        case .lastAck: "LAST_ACK"
        case .finWait2: "FIN_WAIT_2"
        case .timeWait: "TIME_WAIT"
        }
    }
}

/// One socket endpoint pair (inet sockets). `local`/`remote` are formatted `host:port` strings.
public struct SocketEndpoint: Sendable, Hashable {
    public enum Family: Sendable, Hashable { case ipv4, ipv6, unix, other }
    public enum TransportProtocol: Sendable, Hashable { case tcp, udp, other }

    public var family: Family
    public var proto: TransportProtocol
    public var local: String
    public var remote: String
    public var localPort: UInt16
    public var remotePort: UInt16
    public var state: TCPState?

    public init(family: Family, proto: TransportProtocol, local: String, remote: String, localPort: UInt16 = 0,
                remotePort: UInt16 = 0, state: TCPState? = nil) {
        self.family = family
        self.proto = proto
        self.local = local
        self.remote = remote
        self.localPort = localPort
        self.remotePort = remotePort
        self.state = state
    }
}

public struct OpenDescriptor: Sendable, Hashable, Identifiable {
    public enum Kind: Sendable, Hashable {
        case file, directory, tcpSocket, udpSocket, unixSocket, pipe, kqueue, other
    }

    public var fd: Int32
    public var kind: Kind
    /// File path (vnodes) or socket path (unix sockets).
    public var path: String?
    /// Access mode for vnodes: "r", "w" or "rw".
    public var mode: String?
    public var socket: SocketEndpoint?
    /// Pipe peer identity for pipes ("pipe 0x..., peer 0x...").
    public var detail: String?

    public var id: Int32 { fd }

    public init(fd: Int32, kind: Kind, path: String? = nil, mode: String? = nil, socket: SocketEndpoint? = nil,
                detail: String? = nil) {
        self.fd = fd
        self.kind = kind
        self.path = path
        self.mode = mode
        self.socket = socket
        self.detail = detail
    }
}

/// On-demand open-file/socket/pipe listing for one process (Inspector tab). Never run per tick.
public actor FileDescriptorInspector {
    private let source: any FDSource

    public init(source: any FDSource = LiveFDSource()) {
        self.source = source
    }

    /// All descriptors of `pid`. Throws `SourceError` (`isGone`/`isDenied`) when the list itself fails;
    /// a single fd that vanishes or can't be read between calls is returned as `.other`/skipped.
    public func descriptors(pid: pid_t) async throws -> [OpenDescriptor] {
        let entries = try source.listFDs(pid: pid)
        var result: [OpenDescriptor] = []
        result.reserveCapacity(entries.count)
        for entry in entries {
            if let d = describe(entry, pid: pid) { result.append(d) }
        }
        return result.sorted { $0.fd < $1.fd }
    }

    private func describe(_ entry: FDEntry, pid: pid_t) -> OpenDescriptor? {
        switch entry.type {
        case .vnode:
            guard let v = try? source.vnodeInfo(pid: pid, fd: entry.fd) else {
                return OpenDescriptor(fd: entry.fd, kind: .other)
            }
            return OpenDescriptor(fd: entry.fd, kind: Self.isDirectory(v.path) ? .directory : .file,
                                  path: v.path.isEmpty ? nil : v.path, mode: Self.mode(v.openFlags))
        case .socket:
            guard let s = try? source.socketInfo(pid: pid, fd: entry.fd) else {
                return OpenDescriptor(fd: entry.fd, kind: .other)
            }
            return Self.describe(socket: s, fd: entry.fd)
        case .pipe:
            let detail = (try? source.pipeInfo(pid: pid, fd: entry.fd)).map {
                "pipe 0x\(String($0.handle, radix: 16)), peer 0x\(String($0.peerHandle, radix: 16))"
            }
            return OpenDescriptor(fd: entry.fd, kind: .pipe, detail: detail)
        case .kqueue:
            return OpenDescriptor(fd: entry.fd, kind: .kqueue)
        case .other:
            return OpenDescriptor(fd: entry.fd, kind: .other)
        }
    }

    static func describe(socket s: RawSocketInfo, fd: Int32) -> OpenDescriptor {
        switch s.kind {
        case .unix:
            let ep = SocketEndpoint(family: .unix, proto: .other, local: s.unixPath ?? "", remote: s.unixPeerPath ?? "")
            return OpenDescriptor(fd: fd, kind: .unixSocket, path: s.unixPath, socket: ep)
        case .tcp, .inet:
            let isTCP = s.kind == .tcp
            let proto: SocketEndpoint.TransportProtocol = isTCP ? .tcp : (s.proto == IPPROTO_UDP ? .udp : .other)
            let ep = SocketEndpoint(
                family: s.isIPv6 ? .ipv6 : .ipv4, proto: proto,
                local: AddressFormatter.endpoint(address: s.localAddress, port: s.localPort),
                remote: s.remotePort == 0 && AddressFormatter.isUnspecified(s.remoteAddress)
                    ? "*:*" : AddressFormatter.endpoint(address: s.remoteAddress, port: s.remotePort),
                localPort: s.localPort, remotePort: s.remotePort,
                state: isTCP ? TCPState(rawValue: s.tcpState) : nil)
            return OpenDescriptor(fd: fd, kind: isTCP ? .tcpSocket : (proto == .udp ? .udpSocket : .other), socket: ep)
        case .other:
            return OpenDescriptor(fd: fd, kind: .other)
        }
    }

    static func mode(_ flags: UInt32) -> String {
        let r = flags & UInt32(FREAD) != 0
        let w = flags & UInt32(FWRITE) != 0
        return r && w ? "rw" : (w ? "w" : "r")
    }

    private static func isDirectory(_ path: String) -> Bool {
        var st = stat()
        return !path.isEmpty && stat(path, &st) == 0 && (st.st_mode & S_IFMT) == S_IFDIR
    }
}
