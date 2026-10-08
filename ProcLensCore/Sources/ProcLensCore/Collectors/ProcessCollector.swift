import Darwin
import ProcLensHelperProtocol

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

    /// Thread counts of helper-backed pids are refreshed every n-th helper request.
    static let helperInfoInterval: UInt64 = 5

    private struct HelperRequest {
        var generation: UInt64
        /// Tick instant of the request; rates of helper-backed pids are computed against it.
        var instant: ContinuousClock.Instant
        var targets: [pid_t: ProcessID]
        var withInfo: Bool
    }

    private let source: any ProcessSource
    private let idleThrottling: Bool
    private let restricted: (any RestrictedProcessSource)?
    private let helperSlowThreshold: Duration
    private let helperTimeout: Duration
    private let helperMaxBackoff: Duration
    private var helperTask: Task<Void, Never>?
    private var helperWatchdog: Task<Void, Never>?
    private var helperGeneration: UInt64 = 0
    private var helperFailures = 0
    private var helperNextAllowed: ContinuousClock.Instant?
    private var helperRequests: UInt64 = 0
    private var helperActive = false
    private var cache: [pid_t: Entry] = [:]
    private var pidBuffer: [pid_t] = []
    private var tick: UInt64 = 0

    /// - Parameter idleThrottling: when true, a process that showed < 0.1% CPU and no disk I/O for
    ///   3 consecutive reads is read only every other tick (its last sample is reused in between and
    ///   rates are computed over the real interval). Halves the dominant syscall cost on mostly-idle
    ///   systems; a process waking up is noticed up to 1 tick later. Default off.
    ///   - restricted: optional privileged source for processes `proc_pid_rusage` denies. While it is enabled, one
    ///     batched request per tick runs in the background (the tick never waits for it); its reply is merged into
    ///     the cache and shows from the next tick. Slow (> `helperSlowThreshold`) or failing requests back off
    ///     exponentially (1 s ... `helperMaxBackoff`) and the last values stay.
    public init(source: any ProcessSource, idleThrottling: Bool = false, restricted: (any RestrictedProcessSource)? = nil,
                helperSlowThreshold: Duration = .milliseconds(200),
                helperTimeout: Duration = .seconds(2),
                helperMaxBackoff: Duration = .seconds(30)) {
        self.source = source
        self.idleThrottling = idleThrottling
        self.restricted = restricted
        self.helperSlowThreshold = helperSlowThreshold
        self.helperTimeout = helperTimeout
        self.helperMaxBackoff = helperMaxBackoff
    }

    public func reset() {
        for e in cache.values { e.counters = nil; e.lastRead = nil; e.idleStreak = 0 }
        abandonHelperRequest()
    }

    /// Parsed argv/env for the inspector. On demand only; never on the sampling path.
    public func arguments(for id: ProcessID) async throws -> ProcArgs {
        try ProcArgsParser.parse(source.procArgs(id.pid))
    }

    public func sample(at instant: ContinuousClock.Instant) async throws -> ProcessTable {
        try source.allPIDs(into: &pidBuffer)
        syncHelperEnabled()
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
        driveHelper(at: instant, tick: tick)
        return ProcessTable(processes: table)
    }

    // MARK: - Privileged helper merge

    /// Waits for the in-flight helper request (tests).
    func awaitHelperIdle() async {
        await helperTask?.value
    }

    private func abandonHelperRequest() {
        helperGeneration &+= 1
        helperTask = nil
        helperWatchdog?.cancel()
        helperWatchdog = nil
    }

    /// Helper uninstalled or revoked at runtime: back to "restricted" before this tick's table is built.
    private func syncHelperEnabled() {
        guard let restricted, helperActive, !restricted.isEnabled else { return }
        helperActive = false
        abandonHelperRequest()
        helperFailures = 0; helperNextAllowed = nil
        for e in cache.values where e.sample.viaHelper { Self.revertToRestricted(e) }
    }

    /// Starts at most one background request for the restricted pids still alive this tick.
    private func driveHelper(at instant: ContinuousClock.Instant, tick: UInt64) {
        guard let restricted, restricted.isEnabled else { return }
        helperActive = true
        guard helperTask == nil else { return }
        if let next = helperNextAllowed, instant < next { return }
        var targets: [pid_t: ProcessID] = [:]
        for (pid, e) in cache where !e.usageReadable && e.seen == tick { targets[pid] = e.sample.id }
        guard !targets.isEmpty else { return }

        helperRequests &+= 1
        let withInfo = helperRequests % Self.helperInfoInterval == 1
        helperGeneration &+= 1
        let request = HelperRequest(generation: helperGeneration, instant: instant, targets: targets, withInfo: withInfo)
        let pids = Array(targets.keys)
        let clock = ContinuousClock()
        let started = clock.now
        helperTask = Task {
            do {
                async let usage = restricted.readRusage(pids: pids)
                let infos = withInfo ? try await restricted.readProcessInfo(pids: pids) : []
                let usages = try await usage
                finishHelper(request, usages: usages, infos: infos, elapsed: started.duration(to: clock.now), failed: false)
            } catch {
                finishHelper(request, usages: [], infos: [], elapsed: started.duration(to: clock.now), failed: true)
            }
        }
        let timeout = helperTimeout
        helperWatchdog = Task {
            try? await Task.sleep(for: timeout)
            guard !Task.isCancelled else { return }
            finishHelper(request, usages: [], infos: [], elapsed: timeout, failed: true)
        }
    }

    private func finishHelper(_ request: HelperRequest, usages: [HelperRusage], infos: [HelperProcessInfo],
                              elapsed: Duration, failed: Bool) {
        guard request.generation == helperGeneration else { return }  // superseded (reset / disabled / timed out)
        helperWatchdog?.cancel()
        helperWatchdog = nil
        helperTask = nil
        if !failed { mergeHelper(request, usages: usages, infos: infos) }
        if failed || elapsed > helperSlowThreshold {
            helperFailures += 1
            let seconds = min(Double(1 << min(helperFailures - 1, 10)), Double(helperMaxBackoff.components.seconds))
            helperNextAllowed = request.instant.advanced(by: .seconds(seconds))
        } else {
            helperFailures = 0
            helperNextAllowed = nil
        }
    }

    private func mergeHelper(_ request: HelperRequest, usages: [HelperRusage], infos: [HelperProcessInfo]) {
        for r in usages {
            // The pid must still be the process the request was made for (pid reuse since).
            guard let id = request.targets[r.pid], let e = cache[r.pid], e.sample.id == id, !e.usageReadable else { continue }
            if e.startAbs != 0 && e.startAbs != r.startAbsTime {  // reused between two helper reads: no stale delta
                e.counters = nil; e.lastRead = nil
            }
            e.startAbs = r.startAbsTime
            let usage = ResourceUsage(userTime: r.userTime, systemTime: r.systemTime, physFootprint: r.physFootprint,
                                      diskBytesRead: r.diskBytesRead, diskBytesWritten: r.diskBytesWritten,
                                      billedEnergy: r.billedEnergy, interruptWakeups: r.interruptWakeups,
                                      packageIdleWakeups: r.packageIdleWakeups, startAbsTime: r.startAbsTime)
            Self.apply(usage, to: e, at: request.instant)
            e.sample.isRestricted = false
            e.sample.viaHelper = true
        }
        for i in infos {
            guard let id = request.targets[i.pid], let e = cache[i.pid], e.sample.id == id, e.sample.viaHelper else { continue }
            if i.threadCount > 0 { e.sample.threadCount = i.threadCount }
            if e.sample.path == nil { e.sample.path = i.path }
        }
    }

    private static func revertToRestricted(_ e: Entry) {
        e.counters = nil; e.lastRead = nil; e.startAbs = 0
        e.sample.viaHelper = false
        e.sample.isRestricted = true
        e.sample.memory = 0; e.sample.cpu = 0; e.sample.energy = 0
        e.sample.diskReadPerSec = 0; e.sample.diskWritePerSec = 0
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
