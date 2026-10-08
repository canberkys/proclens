#if DEBUG
import Darwin
import Foundation
import ProcLensCore

/// `ProcessSource` over the synthetic machine in `DemoWorld`. Cumulative counters are closed-form integrals of the
/// same rate curves the live table uses, so `ProcessCollector` derives smoothly varying rates from them.
struct DemoProcessSource: ProcessSource {
    init() { DemoWorld.prepare() }

    func allPIDs() throws -> [pid_t] { DemoWorld.processes.map(\.pid) }

    private func proc(_ pid: pid_t) throws -> DemoProc {
        guard let p = DemoWorld.byPID[pid] else { throw SourceError("demo", errno: ESRCH) }
        return p
    }

    func taskAllInfo(_ pid: pid_t) throws -> TaskAllInfo {
        let p = try proc(pid)
        return TaskAllInfo(pid: p.pid, ppid: p.ppid, uid: p.uid, name: p.name, startTime: p.startTime, flags: 0, status: 2,
                           threadCount: p.restricted ? 0 : p.threads, isTranslated: false)
    }

    func rusage(_ pid: pid_t) throws -> ResourceUsage {
        let p = try proc(pid)
        if p.restricted { throw SourceError("proc_pid_rusage", errno: EPERM) }
        let t = DemoWorld.now
        let age = Double(p.startTime) / 1_000_000
        let uptime = Date().timeIntervalSince1970 - age
        func ns(_ seconds: Double) -> UInt64 { UInt64(max(0, seconds) * 1e9) }
        let cpuSeconds = p.cpu * (p.wave.integral(t) + uptime)
        let diskBytes = p.disk * (p.wave.integral(t) + uptime)
        let wakeups = 40 * (t + uptime) + 500 * p.cpu * (p.wave.integral(t) + uptime)
        return ResourceUsage(userTime: ns(cpuSeconds * 0.8), systemTime: ns(cpuSeconds * 0.2), physFootprint: p.memoryNow(t),
                             diskBytesRead: UInt64(max(0, diskBytes * 0.7)), diskBytesWritten: UInt64(max(0, diskBytes * 0.3)),
                             billedEnergy: 0, interruptWakeups: UInt64(max(0, wakeups * 0.6)),
                             packageIdleWakeups: UInt64(max(0, wakeups * 0.4)), startAbsTime: p.startAbs)
    }

    func path(_ pid: pid_t) throws -> String {
        let p = try proc(pid)
        guard !p.restricted, let path = p.path else { throw SourceError("proc_pidpath", errno: EPERM) }
        return path
    }

    func procArgs(_ pid: pid_t) throws -> [UInt8] {
        let p = try proc(pid)
        if p.restricted { throw SourceError("sysctl(KERN_PROCARGS2)", errno: EPERM) }
        var argc = Int32(p.argv.count)
        var out = withUnsafeBytes(of: &argc) { Array($0) }
        out += Array((p.path ?? p.name).utf8) + [0, 0, 0]
        for a in p.argv { out += Array(a.utf8) + [0] }
        var env = [
            "PATH=/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin", "HOME=/Users/demo", "USER=demo", "LOGNAME=demo",
            "SHELL=/bin/zsh", "TMPDIR=/var/folders/zz/demo0000/T/", "LANG=en_US.UTF-8", "__CF_USER_TEXT_ENCODING=0x1F5:0:0",
            "XPC_FLAGS=0x0", "PWD=/Users/demo/projects/webapp",
        ]
        if p.name.contains("node") || p.name.hasPrefix("next") { env += ["NODE_ENV=development", "FORCE_COLOR=1"] }
        if p.name == "python3" { env += ["DJANGO_SETTINGS_MODULE=api.settings.dev", "PYTHONUNBUFFERED=1"] }
        for e in env { out += Array(e.utf8) + [0] }
        return out
    }
}

/// File descriptors for demo processes: standard streams, a kqueue, pipes and (for listeners) a TCP socket.
struct DemoFDSource: FDSource {
    init() { DemoWorld.prepare() }

    private func proc(_ pid: pid_t) throws -> DemoProc {
        guard let p = DemoWorld.byPID[pid] else { throw SourceError("demo", errno: ESRCH) }
        if p.restricted { throw SourceError("proc_pidinfo(LISTFDS)", errno: EPERM) }
        return p
    }

    func listFDs(pid: pid_t) throws -> [FDEntry] {
        let p = try proc(pid)
        var out = [FDEntry(fd: 0, type: .vnode), FDEntry(fd: 1, type: .vnode), FDEntry(fd: 2, type: .vnode),
                   FDEntry(fd: 3, type: .kqueue), FDEntry(fd: 4, type: .pipe), FDEntry(fd: 5, type: .pipe),
                   FDEntry(fd: 6, type: .vnode)]
        for (i, l) in DemoWorld.listeners.enumerated() where l.pid == pid { out.append(FDEntry(fd: Int32(10 + i), type: .socket)) }
        out.append(FDEntry(fd: 20, type: .socket))
        if p.name.contains("Helper") || p.name.contains("Web Content") { out.append(FDEntry(fd: 21, type: .vnode)) }
        return out
    }

    func vnodeInfo(pid: pid_t, fd: Int32) throws -> RawVnodeInfo {
        let p = try proc(pid)
        switch fd {
        case 0: return RawVnodeInfo(path: "/dev/null", openFlags: UInt32(FREAD))
        case 1, 2: return RawVnodeInfo(path: p.ppid == 1 ? "/dev/null" : "/dev/ttys003", openFlags: UInt32(FREAD | FWRITE))
        case 6: return RawVnodeInfo(path: "/Users/demo/projects/webapp", openFlags: UInt32(FREAD))
        default: return RawVnodeInfo(path: "/Users/demo/Library/Caches/\(p.name.replacingOccurrences(of: " ", with: ""))/index.db", openFlags: UInt32(FREAD | FWRITE))
        }
    }

    func socketInfo(pid: pid_t, fd: Int32) throws -> RawSocketInfo {
        _ = try proc(pid)
        if fd == 20 {
            return RawSocketInfo(kind: .unix, family: AF_UNIX, proto: 0, unixPath: "/private/tmp/com.apple.launchd.demo/Listeners")
        }
        let index = Int(fd) - 10
        guard DemoWorld.listeners.indices.contains(index), DemoWorld.listeners[index].pid == pid else {
            throw SourceError("proc_pidfdinfo(SOCKETINFO)", errno: EBADF)
        }
        let l = DemoWorld.listeners[index]
        return RawSocketInfo(kind: .tcp, family: AF_INET, proto: IPPROTO_TCP, isIPv6: false,
                             localAddress: l.loopbackOnly ? [127, 0, 0, 1] : [0, 0, 0, 0], remoteAddress: [0, 0, 0, 0],
                             localPort: l.port, remotePort: 0, tcpState: TCPState.listen.rawValue)
    }

    func pipeInfo(pid: pid_t, fd: Int32) throws -> RawPipeInfo {
        _ = try proc(pid)
        let base = UInt64(pid) << 16
        return RawPipeInfo(handle: 0xFFFF_8000_0000_0000 | base | UInt64(fd), peerHandle: 0xFFFF_8000_0000_0000 | base | UInt64(fd + 1))
    }
}

/// Memory-mapped files for the inspector's Images tab.
struct DemoRegionSource: RegionSource {
    func region(pid: pid_t, atOrAfter address: UInt64) throws -> MemoryRegion? {
        guard let p = DemoWorld.byPID[pid] else { throw SourceError("demo", errno: ESRCH) }
        if p.restricted { throw SourceError("proc_pidinfo(REGIONPATHINFO)", errno: EPERM) }
        let paths = [p.path ?? "/usr/bin/\(p.name)", "/usr/lib/dyld", "/usr/lib/libSystem.B.dylib",
                     "/System/Library/dyld/dyld_shared_cache_arm64e",
                     "/Library/Preferences/Logging/com.apple.diagnostics.mapping",
                     "/private/var/db/CoreDuet/Knowledge/knowledgeC.db-shm"]
        let r: UInt32 = 0x4  // VM_PROT_EXECUTE
        let stride: UInt64 = 0x400_0000
        for (i, path) in paths.enumerated() {
            let start = 0x1_0000_0000 + UInt64(i) * stride
            if start >= address { return MemoryRegion(address: start, size: 0x20_0000 + UInt64(i) * 0x8000, protection: i < 4 ? (r | 1) : UInt32(3), path: path) }
        }
        return nil
    }
}

actor DemoCollector<S: Sendable>: Collector {
    typealias Sample = S
    nonisolated let id: CollectorID
    nonisolated let cost = CollectorCost.perTick
    private let make: @Sendable (Double) -> S

    init(_ name: String, _ make: @escaping @Sendable (Double) -> S) {
        id = CollectorID("demo-\(name)")
        self.make = make
    }

    func sample(at instant: ContinuousClock.Instant) async throws -> S { make(DemoWorld.now) }
    func reset() {}
}
#endif
