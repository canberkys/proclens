import Darwin
import Foundation
import ProcLensHelperProtocol

/// Implements `ProcLensHelperXPC` as root. Every request is validated by `HelperPolicy` first;
/// `/bin/launchctl` and `/usr/bin/sfltool` run with fixed argv (no shell).
final class HelperService: NSObject, ProcLensHelperXPC, @unchecked Sendable {
    private static let build = "1"

    // MARK: Replies

    private func respond<T: Codable & Sendable>(_ reply: @Sendable (Data) -> Void, _ body: () throws -> T) {
        do { reply(HelperCodec.encodeReply(try body())) } catch {
            reply(HelperCodec.encodeFailure(error, as: T.self))
        }
    }

    func helperVersion(reply: @escaping @Sendable (Data) -> Void) {
        respond(reply) { HelperVersionInfo(protocolVersion: HelperConstants.protocolVersion, build: Self.build) }
    }

    // MARK: Process data

    func readRusage(request: Data, reply: @escaping @Sendable (Data) -> Void) {
        respond(reply) { () throws -> [HelperRusage] in
            let pids = try Self.pids(from: request, defaultAll: true)
            return pids.compactMap { Self.rusage(pid: $0) }
        }
    }

    func readProcessInfo(request: Data, reply: @escaping @Sendable (Data) -> Void) {
        respond(reply) { () throws -> [HelperProcessInfo] in
            let pids = try Self.pids(from: request, defaultAll: true)
            return pids.compactMap { Self.processInfo(pid: $0) }
        }
    }

    func listListeningSockets(request: Data, reply: @escaping @Sendable (Data) -> Void) {
        respond(reply) { () throws -> [HelperListeningSocket] in
            let pids = try Self.pids(from: request, defaultAll: true)
            return pids.flatMap { Self.listeningSockets(pid: $0) }
        }
    }

    func signalProcess(request: Data, reply: @escaping @Sendable (Data) -> Void) {
        respond(reply) { () throws -> HelperEmpty in
            let req = try HelperCodec.decode(HelperSignalRequest.self, from: request)
            try HelperPolicy.validateSignal(pid: req.pid, signal: req.signal, helperPID: getpid())
            guard let info = Self.processInfo(pid: req.pid) else {
                throw HelperFailure(code: .notFound, message: "Process \(req.pid) no longer exists.")
            }
            try HelperPolicy.validateTarget(name: info.name)
            guard info.startTime == req.expectedStartTime else {
                throw HelperFailure(code: .processChanged, message: "Process \(req.pid) was replaced by another process.")
            }
            guard kill(req.pid, req.signal) == 0 else {
                throw HelperFailure(code: .commandFailed, message: String(cString: strerror(errno)))
            }
            return HelperEmpty()
        }
    }

    // MARK: Commands

    func launchctl(request: Data, reply: @escaping @Sendable (Data) -> Void) {
        respond(reply) { () throws -> HelperCommandOutput in
            let req = try HelperCodec.decode(HelperLaunchctlRequest.self, from: request)
            let arguments = try HelperPolicy.launchctlArguments(for: req)
            if req.verb == .bootstrap, let path = req.plistPath { try Self.checkPlistFile(path) }
            return try Self.run(HelperPolicy.launchctlPath, arguments, timeout: 20)
        }
    }

    func dumpBTM(reply: @escaping @Sendable (Data) -> Void) {
        respond(reply) { () throws -> HelperCommandOutput in
            try Self.run(HelperPolicy.sfltoolPath, ["dumpbtm"], timeout: 30)
        }
    }

    // MARK: Helpers

    private static func run(_ executable: String, _ arguments: [String], timeout: TimeInterval) throws -> HelperCommandOutput {
        do {
            let result = try SubprocessRunner.run(executable: executable, arguments: arguments, timeout: timeout)
            if result.timedOut { throw HelperFailure(code: .timedOut, message: "\(executable) timed out.") }
            return HelperCommandOutput(exitStatus: result.status, stdout: result.stdout, stderr: result.stderr)
        } catch SubprocessError.launchFailed(let message) {
            throw HelperFailure(code: .commandFailed, message: message)
        }
    }

    /// A bootstrap plist must be a regular, root-owned file that no one else can write (no symlinks).
    private static func checkPlistFile(_ path: String) throws {
        var st = stat()
        guard lstat(path, &st) == 0 else { throw HelperFailure(code: .notFound, message: "Plist not found.") }
        guard (st.st_mode & S_IFMT) == S_IFREG, st.st_uid == 0, st.st_mode & (S_IWGRP | S_IWOTH) == 0 else {
            throw HelperFailure(code: .forbidden, message: "Plist must be a regular root-owned file not writable by others.")
        }
    }

    private static func pids(from request: Data, defaultAll: Bool) throws -> [Int32] {
        let req = try HelperCodec.decode(HelperPIDRequest.self, from: request)
        try HelperPolicy.validatePIDs(req.pids)
        if !req.pids.isEmpty || !defaultAll { return req.pids }
        let count = proc_listallpids(nil, 0)
        guard count > 0 else { return [] }
        var buffer = [pid_t](repeating: 0, count: Int(count) + 64)
        let got = proc_listallpids(&buffer, Int32(buffer.count * MemoryLayout<pid_t>.stride))
        return got > 0 ? buffer.prefix(Int(got)).filter { $0 > 0 } : []
    }

    private static let timebase: (numer: UInt64, denom: UInt64) = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return (UInt64(info.numer), UInt64(max(info.denom, 1)))
    }()

    private static func nanos(_ ticks: UInt64) -> UInt64 {
        let (n, d) = timebase
        if n == d { return ticks }
        let (q, r) = ticks.quotientAndRemainder(dividingBy: d)
        return q &* n &+ (r &* n) / d
    }

    private static func string(from buffer: [CChar]) -> String {
        let bytes = buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
        return String(decoding: bytes, as: UTF8.self)
    }

    static func rusage(pid: Int32) -> HelperRusage? {
        var ri = rusage_info_v4()
        let rc = withUnsafeMutablePointer(to: &ri) { ptr in
            ptr.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V4, $0) }
        }
        guard rc == 0 else { return nil }
        return HelperRusage(
            pid: pid, userTime: nanos(ri.ri_user_time), systemTime: nanos(ri.ri_system_time),
            physFootprint: ri.ri_phys_footprint, diskBytesRead: ri.ri_diskio_bytesread,
            diskBytesWritten: ri.ri_diskio_byteswritten, billedEnergy: ri.ri_billed_energy,
            interruptWakeups: ri.ri_interrupt_wkups, packageIdleWakeups: ri.ri_pkg_idle_wkups,
            startAbsTime: ri.ri_proc_start_abstime)
    }

    static func processInfo(pid: Int32) -> HelperProcessInfo? {
        var bsd = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &bsd, size) == size else { return nil }
        var task = proc_taskinfo()
        let taskSize = Int32(MemoryLayout<proc_taskinfo>.size)
        let threads: Int32 = proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &task, taskSize) == taskSize ? task.pti_threadnum : 0

        var pathBuffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let pathLength = proc_pidpath(pid, &pathBuffer, UInt32(pathBuffer.count))
        let path = pathLength > 0 ? string(from: pathBuffer) : nil
        let name = withUnsafeBytes(of: bsd.pbi_name) { raw -> String in
            let s = String(cString: raw.bindMemory(to: CChar.self).baseAddress!)
            return s.isEmpty ? withUnsafeBytes(of: bsd.pbi_comm) { String(cString: $0.bindMemory(to: CChar.self).baseAddress!) } : s
        }
        return HelperProcessInfo(
            pid: pid, ppid: Int32(bitPattern: bsd.pbi_ppid), uid: bsd.pbi_uid, name: name, path: path,
            startTime: bsd.pbi_start_tvsec &* 1_000_000 &+ bsd.pbi_start_tvusec, threadCount: threads)
    }

    static func listeningSockets(pid: Int32) -> [HelperListeningSocket] {
        let bytes = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
        guard bytes > 0 else { return [] }
        let stride = MemoryLayout<proc_fdinfo>.stride
        var fds = [proc_fdinfo](repeating: proc_fdinfo(), count: Int(bytes) / stride + 8)
        let got = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, &fds, Int32(fds.count * stride))
        guard got > 0 else { return [] }

        var result: [HelperListeningSocket] = []
        for fd in fds.prefix(Int(got) / stride) where fd.proc_fdtype == UInt32(PROX_FDTYPE_SOCKET) {
            var info = socket_fdinfo()
            let size = Int32(MemoryLayout<socket_fdinfo>.size)
            guard proc_pidfdinfo(pid, fd.proc_fd, PROC_PIDFDSOCKETINFO, &info, size) == size else { continue }
            let kind = info.psi.soi_kind
            if kind == SOCKINFO_TCP {
                let tcp = info.psi.soi_proto.pri_tcp
                guard tcp.tcpsi_state == TSI_S_LISTEN else { continue }
                result.append(socket(pid: pid, transport: .tcp, ini: tcp.tcpsi_ini))
            } else if kind == SOCKINFO_IN, info.psi.soi_protocol == IPPROTO_UDP {
                result.append(socket(pid: pid, transport: .udp, ini: info.psi.soi_proto.pri_in))
            }
        }
        return result.filter { $0.port != 0 }
    }

    private static func socket(pid: Int32, transport: HelperListeningSocket.TransportProtocol, ini: in_sockinfo) -> HelperListeningSocket {
        let v6 = (ini.insi_vflag & UInt8(INI_IPV6)) != 0
        var text = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
        if v6 {
            var addr = ini.insi_laddr.ina_6
            inet_ntop(AF_INET6, &addr, &text, socklen_t(text.count))
        } else {
            var addr = ini.insi_laddr.ina_46.i46a_addr4
            inet_ntop(AF_INET, &addr, &text, socklen_t(text.count))
        }
        return HelperListeningSocket(
            pid: pid, transport: transport, localAddress: string(from: text),
            port: UInt16(bigEndian: UInt16(truncatingIfNeeded: ini.insi_lport)), isIPv6: v6)
    }
}
