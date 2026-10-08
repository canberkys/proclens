import Foundation
import Darwin
@testable import ProcLensCore

/// Scripted `ProcessSource`. Tests mutate `state` between collector ticks.
final class MockProcessSource: ProcessSource, @unchecked Sendable {
    struct Entry {
        var info: TaskAllInfo
        var usage: ResourceUsage?
        var infoError: SourceError?
        var usageError: SourceError?
        var path: String?
        var args: [UInt8] = []
    }

    private let lock = NSLock()
    private var entries: [pid_t: Entry] = [:]
    private(set) var pathCalls = 0
    private(set) var procArgsCalls = 0
    private(set) var infoCalls = 0
    private(set) var rusageCalls = 0
    private(set) var threadCalls = 0
    private(set) var shortCalls = 0
    func resetCounts() { lock.withLock { infoCalls = 0; rusageCalls = 0; threadCalls = 0; shortCalls = 0 } }

    func set(_ entry: Entry) { lock.withLock { entries[entry.info.pid] = entry } }
    func remove(_ pid: pid_t) { lock.withLock { _ = entries.removeValue(forKey: pid) } }
    func update(_ pid: pid_t, _ body: (inout Entry) -> Void) {
        lock.withLock { if var e = entries[pid] { body(&e); entries[pid] = e } }
    }

    static func entry(pid: pid_t, start: UInt64 = 1_000, name: String = "p", cpuNanos: UInt64 = 0, read: UInt64 = 0,
                      written: UInt64 = 0, wakeups: UInt64 = 0, footprint: UInt64 = 4096) -> Entry {
        Entry(info: TaskAllInfo(pid: pid, ppid: 1, uid: 501, name: name, startTime: start, flags: 0, status: 0,
                                threadCount: 2, isTranslated: false),
              usage: ResourceUsage(userTime: cpuNanos, systemTime: 0, physFootprint: footprint, diskBytesRead: read,
                                   diskBytesWritten: written, billedEnergy: 0, interruptWakeups: wakeups,
                                   packageIdleWakeups: 0, startAbsTime: start),
              path: "/bin/\(name)")
    }

    func allPIDs() throws -> [pid_t] { lock.withLock { entries.keys.sorted() } }

    func taskAllInfo(_ pid: pid_t) throws -> TaskAllInfo {
        try lock.withLock {
            infoCalls += 1
            guard let e = entries[pid] else { throw SourceError("proc_pidinfo", errno: ESRCH) }
            if let err = e.infoError { throw err }
            return e.info
        }
    }

    func rusage(_ pid: pid_t) throws -> ResourceUsage {
        try lock.withLock {
            rusageCalls += 1
            guard let e = entries[pid] else { throw SourceError("proc_pid_rusage", errno: ESRCH) }
            if let err = e.usageError { throw err }
            guard let u = e.usage else { throw SourceError("proc_pid_rusage", errno: EPERM) }
            return u
        }
    }

    func threadCount(_ pid: pid_t) throws -> Int32 {
        try lock.withLock {
            threadCalls += 1
            guard let e = entries[pid] else { throw SourceError("proc_pidinfo", errno: ESRCH) }
            return e.info.threadCount
        }
    }

    func shortInfo(_ pid: pid_t) throws -> ShortInfo {
        try lock.withLock {
            shortCalls += 1
            guard let e = entries[pid] else { throw SourceError("proc_pidinfo", errno: ESRCH) }
            return ShortInfo(ppid: e.info.ppid, uid: e.info.uid, name: e.info.name)
        }
    }

    func path(_ pid: pid_t) throws -> String {
        try lock.withLock {
            pathCalls += 1
            guard let p = entries[pid]?.path else { throw SourceError("proc_pidpath", errno: ESRCH) }
            return p
        }
    }

    func procArgs(_ pid: pid_t) throws -> [UInt8] {
        try lock.withLock {
            procArgsCalls += 1
            guard let e = entries[pid] else { throw SourceError("sysctl", errno: ESRCH) }
            return e.args
        }
    }
}
