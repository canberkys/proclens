import Darwin

/// Kind of a file descriptor as reported by `PROC_PIDLISTFDS` (`proc_fdtype`).
public enum FDType: Sendable, Hashable {
    case vnode, socket, pipe, kqueue, other(UInt32)

    init(raw: UInt32) {
        switch raw {
        case UInt32(PROX_FDTYPE_VNODE): self = .vnode
        case UInt32(PROX_FDTYPE_SOCKET): self = .socket
        case UInt32(PROX_FDTYPE_PIPE): self = .pipe
        case UInt32(PROX_FDTYPE_KQUEUE): self = .kqueue
        default: self = .other(raw)
        }
    }
}

public struct FDEntry: Sendable, Hashable {
    public var fd: Int32
    public var type: FDType
    public init(fd: Int32, type: FDType) {
        self.fd = fd
        self.type = type
    }
}

/// Raw vnode info for one fd.
public struct RawVnodeInfo: Sendable, Hashable {
    public var path: String
    /// `fi_openflags` (`FREAD`/`FWRITE`/...).
    public var openFlags: UInt32
    public init(path: String, openFlags: UInt32) {
        self.path = path
        self.openFlags = openFlags
    }
}

/// Raw socket info for one fd, address bytes still in network order (4 or 16 bytes).
public struct RawSocketInfo: Sendable, Hashable {
    public enum Kind: Sendable, Hashable { case tcp, inet, unix, other }
    public var kind: Kind
    /// `soi_family` (`AF_INET`, `AF_INET6`, `AF_UNIX`...).
    public var family: Int32
    /// `soi_protocol` (`IPPROTO_TCP`, `IPPROTO_UDP`...).
    public var proto: Int32
    public var isIPv6: Bool
    public var localAddress: [UInt8]
    public var remoteAddress: [UInt8]
    /// Host byte order.
    public var localPort: UInt16
    public var remotePort: UInt16
    /// `tcpsi_state` (`TSI_S_*`), TCP only.
    public var tcpState: Int32
    public var unixPath: String?
    public var unixPeerPath: String?

    public init(kind: Kind, family: Int32, proto: Int32, isIPv6: Bool = false, localAddress: [UInt8] = [],
                remoteAddress: [UInt8] = [], localPort: UInt16 = 0, remotePort: UInt16 = 0, tcpState: Int32 = 0,
                unixPath: String? = nil, unixPeerPath: String? = nil) {
        self.kind = kind
        self.family = family
        self.proto = proto
        self.isIPv6 = isIPv6
        self.localAddress = localAddress
        self.remoteAddress = remoteAddress
        self.localPort = localPort
        self.remotePort = remotePort
        self.tcpState = tcpState
        self.unixPath = unixPath
        self.unixPeerPath = unixPeerPath
    }
}

public struct RawPipeInfo: Sendable, Hashable {
    public var handle: UInt64
    public var peerHandle: UInt64
    public init(handle: UInt64, peerHandle: UInt64) {
        self.handle = handle
        self.peerHandle = peerHandle
    }
}

/// Per-fd libproc syscalls. Every call may throw `ESRCH` (gone) or `EPERM` (restricted).
public protocol FDSource: Sendable {
    func listFDs(pid: pid_t) throws -> [FDEntry]
    func vnodeInfo(pid: pid_t, fd: Int32) throws -> RawVnodeInfo
    func socketInfo(pid: pid_t, fd: Int32) throws -> RawSocketInfo
    func pipeInfo(pid: pid_t, fd: Int32) throws -> RawPipeInfo
}

/// Public libproc implementation (`PROC_PIDLISTFDS`, `PROC_PIDFD*`). No shelling out.
public struct LiveFDSource: FDSource {
    public init() {}

    public func listFDs(pid: pid_t) throws -> [FDEntry] {
        let stride = MemoryLayout<proc_fdinfo>.stride
        // Size query, then fetch with headroom for fds opened in between.
        let needed = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
        if needed < 0 { throw SourceError("proc_pidinfo(LISTFDS)", errno: errno) }
        if needed == 0 { return [] }
        let capacity = Int(needed) / stride + 16
        var buffer = [proc_fdinfo](repeating: proc_fdinfo(), count: capacity)
        let got = buffer.withUnsafeMutableBytes {
            proc_pidinfo(pid, PROC_PIDLISTFDS, 0, $0.baseAddress, Int32($0.count))
        }
        if got < 0 { throw SourceError("proc_pidinfo(LISTFDS)", errno: errno) }
        let count = min(Int(got) / stride, capacity)
        var result: [FDEntry] = []
        result.reserveCapacity(count)
        for i in 0..<count {
            result.append(FDEntry(fd: buffer[i].proc_fd, type: FDType(raw: buffer[i].proc_fdtype)))
        }
        return result
    }

    public func vnodeInfo(pid: pid_t, fd: Int32) throws -> RawVnodeInfo {
        var info = vnode_fdinfowithpath()
        let size = Int32(MemoryLayout<vnode_fdinfowithpath>.size)
        let got = proc_pidfdinfo(pid, fd, PROC_PIDFDVNODEPATHINFO, &info, size)
        if got < size { throw SourceError("proc_pidfdinfo(VNODEPATHINFO)", errno: got < 0 ? errno : EIO) }
        let path = withUnsafeBytes(of: &info.pvip.vip_path) {
            String(cString: $0.bindMemory(to: CChar.self).baseAddress!)
        }
        return RawVnodeInfo(path: path, openFlags: info.pfi.fi_openflags)
    }

    public func socketInfo(pid: pid_t, fd: Int32) throws -> RawSocketInfo {
        var info = socket_fdinfo()
        let size = Int32(MemoryLayout<socket_fdinfo>.size)
        let got = proc_pidfdinfo(pid, fd, PROC_PIDFDSOCKETINFO, &info, size)
        if got < size { throw SourceError("proc_pidfdinfo(SOCKETINFO)", errno: got < 0 ? errno : EIO) }
        return Self.convert(info.psi)
    }

    public func pipeInfo(pid: pid_t, fd: Int32) throws -> RawPipeInfo {
        var info = pipe_fdinfo()
        let size = Int32(MemoryLayout<pipe_fdinfo>.size)
        let got = proc_pidfdinfo(pid, fd, PROC_PIDFDPIPEINFO, &info, size)
        if got < size { throw SourceError("proc_pidfdinfo(PIPEINFO)", errno: got < 0 ? errno : EIO) }
        return RawPipeInfo(handle: info.pipeinfo.pipe_handle, peerHandle: info.pipeinfo.pipe_peerhandle)
    }

    static func convert(_ s: socket_info) -> RawSocketInfo {
        let family = s.soi_family
        let proto = s.soi_protocol
        switch Int(s.soi_kind) {
        case Int(SOCKINFO_TCP):
            let tcp = s.soi_proto.pri_tcp
            return convertIn(tcp.tcpsi_ini, kind: .tcp, family: family, proto: proto, tcpState: tcp.tcpsi_state)
        case Int(SOCKINFO_IN):
            return convertIn(s.soi_proto.pri_in, kind: .inet, family: family, proto: proto, tcpState: 0)
        case Int(SOCKINFO_UN):
            var un = s.soi_proto.pri_un
            let local = withUnsafeBytes(of: &un.unsi_addr.ua_sun.sun_path) {
                String(cString: $0.bindMemory(to: CChar.self).baseAddress!)
            }
            let peer = withUnsafeBytes(of: &un.unsi_caddr.ua_sun.sun_path) {
                String(cString: $0.bindMemory(to: CChar.self).baseAddress!)
            }
            return RawSocketInfo(kind: .unix, family: family, proto: proto,
                                 unixPath: local.isEmpty ? nil : local, unixPeerPath: peer.isEmpty ? nil : peer)
        default:
            return RawSocketInfo(kind: .other, family: family, proto: proto)
        }
    }

    private static func convertIn(_ ini: in_sockinfo, kind: RawSocketInfo.Kind, family: Int32, proto: Int32,
                                  tcpState: Int32) -> RawSocketInfo {
        let v6 = (ini.insi_vflag & UInt8(INI_IPV6)) != 0
        // `insi_laddr` is a union (`in4in6_addr` / `in6_addr`); read the right member.
        let local: [UInt8] = v6
            ? withUnsafeBytes(of: ini.insi_laddr.ina_6) { Array($0) }
            : withUnsafeBytes(of: ini.insi_laddr.ina_46.i46a_addr4) { Array($0) }
        let remote: [UInt8] = v6
            ? withUnsafeBytes(of: ini.insi_faddr.ina_6) { Array($0) }
            : withUnsafeBytes(of: ini.insi_faddr.ina_46.i46a_addr4) { Array($0) }
        return RawSocketInfo(
            kind: kind, family: family, proto: proto, isIPv6: v6, localAddress: local, remoteAddress: remote,
            localPort: UInt16(bigEndian: UInt16(truncatingIfNeeded: ini.insi_lport)),
            remotePort: UInt16(bigEndian: UInt16(truncatingIfNeeded: ini.insi_fport)),
            tcpState: tcpState)
    }
}
