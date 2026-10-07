import Darwin

/// `ProcessSource` backed by libproc and sysctl. Never shells out.
public struct LiveProcessSource: ProcessSource {
    /// `P_TRANSLATED` from `<sys/proc.h>` (Rosetta). Not exported to Swift, so defined here.
    static let pTranslated: UInt32 = 0x0002_0000

    /// Mach absolute time -> nanoseconds. On Apple Silicon `ri_user_time`/`ri_system_time`
    /// are in mach absolute time units (timebase 125/3), on Intel they are already ns (1/1).
    private static let timebase: (numer: UInt64, denom: UInt64) = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return (UInt64(info.numer), UInt64(max(info.denom, 1)))
    }()

    public init() {}

    static func machToNanos(_ ticks: UInt64) -> UInt64 {
        let (n, d) = timebase
        if n == d { return ticks }
        // Split to avoid overflow of ticks * numer for very large counters.
        let (q, r) = ticks.quotientAndRemainder(dividingBy: d)
        return q &* n &+ (r &* n) / d
    }

    public func allPIDs() throws -> [pid_t] {
        var capacity = 0
        let probe = proc_listallpids(nil, 0)
        guard probe > 0 else { throw SourceError("proc_listallpids", errno: errno) }
        capacity = Int(probe) + 64 + Int(probe) / 4
        while true {
            var buffer = [pid_t](repeating: 0, count: capacity)
            let bytes = Int32(capacity * MemoryLayout<pid_t>.size)
            let count = buffer.withUnsafeMutableBytes { proc_listallpids($0.baseAddress, bytes) }
            guard count > 0 else { throw SourceError("proc_listallpids", errno: errno) }
            if Int(count) >= capacity {  // buffer may have been truncated: grow and retry
                capacity *= 2
                continue
            }
            var result: [pid_t] = []
            result.reserveCapacity(Int(count))
            var sawKernel = false
            for pid in buffer[0..<Int(count)] {
                if pid == 0 {
                    if !sawKernel { sawKernel = true; result.append(0) }  // kernel_task once, skip padding
                } else {
                    result.append(pid)
                }
            }
            return result
        }
    }

    public func allPIDs(into buffer: inout [pid_t]) throws {
        if buffer.count < 2048 { buffer = [pid_t](repeating: 0, count: 2048) }
        while true {
            let capacity = buffer.count
            let bytes = Int32(capacity * MemoryLayout<pid_t>.size)
            let count = buffer.withUnsafeMutableBytes { proc_listallpids($0.baseAddress, bytes) }
            guard count > 0 else { throw SourceError("proc_listallpids", errno: errno) }
            if Int(count) >= capacity - 16 {  // possibly truncated: grow and retry
                buffer = [pid_t](repeating: 0, count: capacity * 2)
                continue
            }
            // Compact in place: drop the zero padding but keep kernel_task (pid 0) once.
            var out = 0
            var sawKernel = false
            for i in 0..<Int(count) {
                let pid = buffer[i]
                if pid == 0 {
                    if sawKernel { continue }
                    sawKernel = true
                }
                buffer[out] = pid
                out += 1
            }
            buffer.removeSubrange(out..<buffer.count)  // keeps capacity
            return
        }
    }

    public func threadCount(_ pid: pid_t) throws -> Int32 {
        var info = proc_taskinfo()
        let size = Int32(MemoryLayout<proc_taskinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &info, size) == size else {
            throw SourceError("proc_pidinfo", errno: errno == 0 ? ESRCH : errno)
        }
        return info.pti_threadnum
    }

    public func shortInfo(_ pid: pid_t) throws -> ShortInfo {
        var short = proc_bsdshortinfo()
        let size = Int32(MemoryLayout<proc_bsdshortinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDT_SHORTBSDINFO, 0, &short, size) == size else {
            throw SourceError("proc_pidinfo", errno: errno == 0 ? ESRCH : errno)
        }
        return ShortInfo(ppid: pid_t(short.pbsi_ppid), uid: short.pbsi_uid, name: Self.string(from: short.pbsi_comm))
    }

    public func taskAllInfo(_ pid: pid_t) throws -> TaskAllInfo {
        var info = proc_taskallinfo()
        let size = Int32(MemoryLayout<proc_taskallinfo>.size)
        let n = proc_pidinfo(pid, PROC_PIDTASKALLINFO, 0, &info, size)
        if n == size {
            let bsd = info.pbsd
            let name = Self.string(from: bsd.pbi_name).nonEmpty ?? Self.string(from: bsd.pbi_comm)
            return TaskAllInfo(
                pid: pid, ppid: pid_t(bsd.pbi_ppid), uid: bsd.pbi_uid, name: name,
                startTime: bsd.pbi_start_tvsec &* 1_000_000 &+ bsd.pbi_start_tvusec,
                flags: bsd.pbi_flags, status: bsd.pbi_status, threadCount: info.ptinfo.pti_threadnum,
                isTranslated: bsd.pbi_flags & Self.pTranslated != 0)
        }
        let firstErrno = errno
        // Other users' processes: TASKALLINFO gives EPERM but the short BSD info is readable.
        var short = proc_bsdshortinfo()
        let shortSize = Int32(MemoryLayout<proc_bsdshortinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDT_SHORTBSDINFO, 0, &short, shortSize) == shortSize else {
            throw SourceError("proc_pidinfo", errno: n < 0 ? firstErrno : (errno == 0 ? ESRCH : errno))
        }
        // Start time is not in the short struct; ESRCH-safe fallback via full BSD info if available.
        var bsd = proc_bsdinfo()
        let bsdSize = Int32(MemoryLayout<proc_bsdinfo>.size)
        var start: UInt64 = 0
        if proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &bsd, bsdSize) == bsdSize {
            start = bsd.pbi_start_tvsec &* 1_000_000 &+ bsd.pbi_start_tvusec
        }
        return TaskAllInfo(
            pid: pid, ppid: pid_t(short.pbsi_ppid), uid: short.pbsi_uid, name: Self.string(from: short.pbsi_comm),
            startTime: start, flags: short.pbsi_flags, status: short.pbsi_status, threadCount: 0,
            isTranslated: short.pbsi_flags & Self.pTranslated != 0)
    }

    /// Uses flavor V2 (V6 costs ~2.5x more per call and V2 has every field we use; `billedEnergy` is
    /// therefore always 0, it is unused by the energy model).
    public func rusage(_ pid: pid_t) throws -> ResourceUsage {
        var ri = rusage_info_v2()
        let rc = withUnsafeMutablePointer(to: &ri) { ptr in
            ptr.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                proc_pid_rusage(pid, RUSAGE_INFO_V2, $0)
            }
        }
        guard rc == 0 else { throw SourceError("proc_pid_rusage", errno: errno) }
        return ResourceUsage(
            userTime: Self.machToNanos(ri.ri_user_time), systemTime: Self.machToNanos(ri.ri_system_time),
            physFootprint: ri.ri_phys_footprint, diskBytesRead: ri.ri_diskio_bytesread,
            diskBytesWritten: ri.ri_diskio_byteswritten, billedEnergy: 0,
            interruptWakeups: ri.ri_interrupt_wkups, packageIdleWakeups: ri.ri_pkg_idle_wkups,
            startAbsTime: ri.ri_proc_start_abstime)
    }

    public func path(_ pid: pid_t) throws -> String {
        let maxSize = 4 * Int(MAXPATHLEN)  // PROC_PIDPATHINFO_MAXSIZE (macro not imported)
        var buffer = [CChar](repeating: 0, count: maxSize)
        let n = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard n > 0 else { throw SourceError("proc_pidpath", errno: errno) }
        return String(decoding: buffer[0..<Int(n)].map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    public func procArgs(_ pid: pid_t) throws -> [UInt8] {
        var mib: [Int32] = [CTL_KERN, KERN_ARGMAX]
        var argMax: Int32 = 0
        var len = MemoryLayout<Int32>.size
        guard sysctl(&mib, 2, &argMax, &len, nil, 0) == 0, argMax > 0 else {
            throw SourceError("sysctl(KERN_ARGMAX)", errno: errno)
        }
        var buffer = [UInt8](repeating: 0, count: Int(argMax))
        var size = buffer.count
        var procMib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        guard sysctl(&procMib, 3, &buffer, &size, nil, 0) == 0 else {
            throw SourceError("sysctl(KERN_PROCARGS2)", errno: errno)
        }
        return Array(buffer[0..<size])
    }

    /// Decodes a fixed-size C char tuple (as imported from libproc structs).
    private static func string<T>(from tuple: T) -> String {
        withUnsafeBytes(of: tuple) { raw in
            let bytes = raw.prefix { $0 != 0 }
            return String(decoding: bytes, as: UTF8.self)
        }
    }
}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}
