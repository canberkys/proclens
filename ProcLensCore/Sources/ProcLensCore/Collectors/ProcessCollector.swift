import Darwin

/// Produces a `ProcessTable` each tick from a `ProcessSource`.
///
/// Per-process rates come from deltas of cumulative counters between two ticks, keyed by
/// `ProcessID` (pid + start time) so a reused pid starts from zero instead of inheriting
/// a dead process's counters. Each process's very first reading has all rates at 0.
///
/// Energy (D1) is an APPROXIMATION and NOT Activity Monitor's "Energy Impact":
///
///     energy = 100 * cpu + 0.05 * wakeupsPerSecond      (clamped >= 0)
///
/// where `cpu` is core-fraction (1.0 = one full core) and wakeups are
/// `ri_interrupt_wkups + ri_pkg_idle_wkups` deltas per second. So a process pinning one
/// core scores ~100, and 2,000 wakeups/s adds ~100. `ri_billed_energy` is not used: it is
/// zero for most processes. Only the relative ordering is meaningful.
public actor ProcessCollector: Collector {
    public typealias Sample = ProcessTable

    public nonisolated let id = CollectorID("processes")
    public nonisolated let cost: CollectorCost = .perTick

    static let cpuEnergyWeight = 100.0
    static let wakeupEnergyWeight = 0.05

    private struct Counters {
        var cpuNanos: UInt64
        var diskRead: UInt64
        var diskWritten: UInt64
        var wakeups: UInt64
    }

    /// Per-pid cache: static identity plus last counters. Mutated in place (reference type).
    private final class Entry {
        var sample: ProcessSample
        /// `ri_proc_start_abstime` captured on the first read; a change means pid reuse.
        var startAbs: UInt64
        /// False when `proc_pid_rusage` is denied: nothing is queried per tick for such pids.
        var usageReadable: Bool
        var counters: Counters?
        var seen: UInt64
        /// Tick instant of the last rusage read (rates use the per-pid interval, so skipped ticks stay exact).
        var lastRead: ContinuousClock.Instant?
        /// Consecutive reads with < 0.1% CPU and no disk I/O.
        var idleStreak = 0
        init(sample: ProcessSample, startAbs: UInt64, usageReadable: Bool, counters: Counters?, seen: UInt64) {
            self.sample = sample
            self.startAbs = startAbs
            self.usageReadable = usageReadable
            self.counters = counters
            self.seen = seen
        }
    }

    /// Thread counts are refreshed every n-th tick (staggered per pid); restricted pids are
    /// re-validated against pid reuse every m-th tick with one cheap call.
    static let threadRefreshInterval: UInt64 = 5
    static let restrictedRevalidateInterval: UInt64 = 10

    /// Reads that must look idle before a process is throttled to every other tick.
    static let idleStreakForThrottle = 3

    private let source: any ProcessSource
    private let idleThrottling: Bool
    private var cache: [pid_t: Entry] = [:]
    private var pidBuffer: [pid_t] = []
    private var tick: UInt64 = 0

    /// - Parameter idleThrottling: when true, a process that showed < 0.1% CPU and no disk I/O for
    ///   3 consecutive reads is read only every other tick (its last sample is reused in between and
    ///   rates are computed over the real interval). Halves the dominant syscall cost on mostly-idle
    ///   systems; a process waking up is noticed up to 1 tick later. Default off.
    public init(source: any ProcessSource, idleThrottling: Bool = false) {
        self.source = source
        self.idleThrottling = idleThrottling
    }

    public func reset() {
        for e in cache.values { e.counters = nil; e.lastRead = nil; e.idleStreak = 0 }
    }

    /// Parsed argv/env for the inspector. On demand only; never on the sampling path.
    public func arguments(for id: ProcessID) async throws -> ProcArgs {
        try ProcArgsParser.parse(source.procArgs(id.pid))
    }

    public func sample(at instant: ContinuousClock.Instant) async throws -> ProcessTable {
        try source.allPIDs(into: &pidBuffer)
        tick &+= 1
        let tick = self.tick

        var table: [ProcessID: ProcessSample] = [:]
        table.reserveCapacity(pidBuffer.count)
        var seenCount = 0

        for pid in pidBuffer {
            let stagger = tick &+ UInt64(UInt32(bitPattern: pid))
            if let e = cache[pid] {
                if e.usageReadable {
                    if idleThrottling, e.idleStreak >= Self.idleStreakForThrottle, stagger & 1 == 1 {
                        e.seen = tick
                        seenCount += 1
                        table[e.sample.id] = e.sample
                        continue
                    }
                    let usage: ResourceUsage
                    do {
                        usage = try source.rusage(pid)
                    } catch let err as SourceError where err.isGone {
                        continue
                    } catch {
                        // Became unreadable: stay in the cache as restricted, stop querying.
                        e.usageReadable = false
                        e.counters = nil
                        e.sample.isRestricted = true
                        e.sample.memory = 0
                        e.sample.cpu = 0; e.sample.energy = 0
                        e.sample.diskReadPerSec = 0; e.sample.diskWritePerSec = 0
                        e.seen = tick; seenCount += 1
                        table[e.sample.id] = e.sample
                        continue
                    }
                    if usage.startAbsTime == e.startAbs {
                        e.seen = tick
                        seenCount += 1
                        if !e.sample.isRestricted, stagger % Self.threadRefreshInterval == 0,
                           let n = try? source.threadCount(pid) {
                            e.sample.threadCount = n
                        }
                        Self.apply(usage, to: e, at: instant)
                        table[e.sample.id] = e.sample
                        continue
                    }
                    // pid reuse: fall through to a full re-read
                } else if stagger % Self.restrictedRevalidateInterval != 0 {
                    e.seen = tick
                    seenCount += 1
                    table[e.sample.id] = e.sample
                    continue
                } else {
                    do {
                        let s = try source.shortInfo(pid)
                        let cur = e.sample
                        if s.ppid == cur.ppid && s.uid == cur.uid && (s.name == cur.name || cur.name.hasPrefix(s.name)) {
                            e.seen = tick
                            seenCount += 1
                            table[cur.id] = cur
                            continue
                        }
                    } catch let err as SourceError where err.isGone {
                        continue
                    } catch {
                        // unreadable: fall through to a full re-read
                    }
                }
            }
            if let e = readFresh(pid, tick: tick, at: instant) {
                cache[pid] = e
                seenCount += 1
                table[e.sample.id] = e.sample
            } else {
                cache[pid] = nil
            }
        }

        if cache.count != seenCount {  // prune vanished processes
            for (pid, e) in cache where e.seen != tick { cache[pid] = nil }
        }
        return ProcessTable(processes: table)
    }

    /// Full identity read for a new (or reused) pid.
    private func readFresh(_ pid: pid_t, tick: UInt64, at instant: ContinuousClock.Instant) -> Entry? {
        let info: TaskAllInfo
        do {
            info = try source.taskAllInfo(pid)
        } catch {
            return nil  // ESRCH (exited) and unreadable pids are skipped
        }
        var restricted = false
        var usage: ResourceUsage?
        do {
            usage = try source.rusage(pid)
        } catch let e as SourceError where e.isGone {
            return nil
        } catch {
            restricted = true  // EPERM etc.
        }
        // The short-info fallback (other users' processes) reports threadCount 0.
        if info.threadCount == 0 && pid != 0 { restricted = true }
        let path = try? source.path(pid)
        let sample = ProcessSample(
            id: info.processID, ppid: info.ppid, uid: info.uid, name: info.name, path: path,
            threadCount: info.threadCount, isTranslated: info.isTranslated, cpu: 0, memory: usage?.physFootprint ?? 0,
            diskReadPerSec: 0, diskWritePerSec: 0, energy: 0, isRestricted: restricted)
        let e = Entry(sample: sample, startAbs: usage?.startAbsTime ?? 0, usageReadable: usage != nil,
                      counters: nil, seen: tick)
        if let usage { Self.apply(usage, to: e, at: instant) }
        return e
    }

    /// Updates counters and rates (all rates 0 without a previous reading).
    private static func apply(_ u: ResourceUsage, to e: Entry, at instant: ContinuousClock.Instant) {
        let elapsed = e.lastRead.map { seconds(from: $0, to: instant) } ?? 0
        let dt: Double? = elapsed > 0 ? elapsed : nil
        e.lastRead = instant
        let counters = Counters(cpuNanos: u.userTime &+ u.systemTime, diskRead: u.diskBytesRead,
                                diskWritten: u.diskBytesWritten, wakeups: u.interruptWakeups &+ u.packageIdleWakeups)
        var cpu = 0.0, readRate = 0.0, writeRate = 0.0, energy = 0.0
        if let dt, let prev = e.counters {
            cpu = Double(delta(counters.cpuNanos, prev.cpuNanos)) / (dt * 1e9)
            readRate = Double(delta(counters.diskRead, prev.diskRead)) / dt
            writeRate = Double(delta(counters.diskWritten, prev.diskWritten)) / dt
            let wakeRate = Double(delta(counters.wakeups, prev.wakeups)) / dt
            energy = cpuEnergyWeight * cpu + wakeupEnergyWeight * wakeRate
        }
        let idle = dt != nil && cpu < 0.001 && readRate == 0 && writeRate == 0
        e.idleStreak = idle ? e.idleStreak + 1 : 0
        e.counters = counters
        e.sample.memory = u.physFootprint
        e.sample.cpu = cpu
        e.sample.diskReadPerSec = readRate
        e.sample.diskWritePerSec = writeRate
        e.sample.energy = energy
    }

    /// Counter delta; a counter that went backwards (should not happen) counts as 0.
    private static func delta(_ new: UInt64, _ old: UInt64) -> UInt64 { new >= old ? new - old : 0 }

    private static func seconds(from a: ContinuousClock.Instant, to b: ContinuousClock.Instant) -> Double {
        let d = a.duration(to: b)
        return Double(d.components.seconds) + Double(d.components.attoseconds) / 1e18
    }
}
