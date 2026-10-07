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

    private let source: any ProcessSource
    private var previous: [ProcessID: Counters] = [:]
    private var previousInstant: ContinuousClock.Instant?
    private var paths: [ProcessID: String] = [:]

    public init(source: any ProcessSource) {
        self.source = source
    }

    public func reset() {
        previous.removeAll(keepingCapacity: true)
        previousInstant = nil
    }

    /// Parsed argv/env for the inspector. On demand only; never on the sampling path.
    public func arguments(for id: ProcessID) async throws -> ProcArgs {
        try ProcArgsParser.parse(source.procArgs(id.pid))
    }

    public func sample(at instant: ContinuousClock.Instant) async throws -> ProcessTable {
        let pids = try source.allPIDs()
        let elapsed: Double? = previousInstant.map { Self.seconds(from: $0, to: instant) }
        let dt = (elapsed ?? 0) > 0 ? elapsed : nil

        var table: [ProcessID: ProcessSample] = [:]
        table.reserveCapacity(pids.count)
        var nextPrevious: [ProcessID: Counters] = [:]
        nextPrevious.reserveCapacity(pids.count)
        var nextPaths: [ProcessID: String] = [:]
        nextPaths.reserveCapacity(pids.count)

        for pid in pids {
            let info: TaskAllInfo
            do {
                info = try source.taskAllInfo(pid)
            } catch {
                continue  // ESRCH (exited) and unreadable pids are skipped
            }
            let pid_ = info.processID

            var restricted = false
            var usage: ResourceUsage?
            do {
                usage = try source.rusage(pid)
            } catch let e as SourceError where e.isGone {
                continue
            } catch {
                restricted = true  // EPERM etc.: keep what we have
            }
            // The short-info fallback (other users' processes) reports threadCount 0.
            if info.threadCount == 0 && pid != 0 { restricted = true }

            var cpu = 0.0, readRate = 0.0, writeRate = 0.0, energy = 0.0
            var memory: UInt64 = 0
            if let u = usage {
                memory = u.physFootprint
                let counters = Counters(cpuNanos: u.userTime &+ u.systemTime, diskRead: u.diskBytesRead,
                                        diskWritten: u.diskBytesWritten,
                                        wakeups: u.interruptWakeups &+ u.packageIdleWakeups)
                if let dt, let prev = previous[pid_] {
                    cpu = Double(Self.delta(counters.cpuNanos, prev.cpuNanos)) / (dt * 1e9)
                    readRate = Double(Self.delta(counters.diskRead, prev.diskRead)) / dt
                    writeRate = Double(Self.delta(counters.diskWritten, prev.diskWritten)) / dt
                    let wakeRate = Double(Self.delta(counters.wakeups, prev.wakeups)) / dt
                    energy = Self.cpuEnergyWeight * cpu + Self.wakeupEnergyWeight * wakeRate
                }
                nextPrevious[pid_] = counters
            }

            var path = paths[pid_]
            if path == nil, let p = try? source.path(pid) { path = p }
            if let path { nextPaths[pid_] = path }

            table[pid_] = ProcessSample(
                id: pid_, ppid: info.ppid, uid: info.uid, name: info.name, path: path,
                threadCount: info.threadCount, isTranslated: info.isTranslated, cpu: cpu, memory: memory,
                diskReadPerSec: readRate, diskWritePerSec: writeRate, energy: energy, isRestricted: restricted)
        }

        previous = nextPrevious  // prunes vanished processes
        paths = nextPaths
        previousInstant = instant
        return ProcessTable(processes: table)
    }

    /// Counter delta; a counter that went backwards (should not happen) counts as 0.
    private static func delta(_ new: UInt64, _ old: UInt64) -> UInt64 { new >= old ? new - old : 0 }

    private static func seconds(from a: ContinuousClock.Instant, to b: ContinuousClock.Instant) -> Double {
        let d = a.duration(to: b)
        return Double(d.components.seconds) + Double(d.components.attoseconds) / 1e18
    }
}
