// ProcLensBench: collector cost measurement (SPEC §8).
//   swift run -c release --package-path ProcLensCore ProcLensBench live [seconds] [only: cpu memory processes gpu disk network ...]
//   swift run -c release --package-path ProcLensCore ProcLensBench synthetic [ticks]
import Darwin
import Foundation
import ProcLensCore

/// Wraps a collector and accumulates wall time spent inside `sample`.
actor TimedCollector<S: Sendable>: Collector {
    typealias Sample = S
    nonisolated let id: CollectorID
    nonisolated let cost: CollectorCost
    private let inner: any Collector<S>
    private(set) var totalNanos: UInt64 = 0
    private(set) var count = 0

    init(_ inner: any Collector<S>) {
        self.inner = inner
        self.id = inner.id
        self.cost = inner.cost
    }

    func sample(at instant: ContinuousClock.Instant) async throws -> S {
        var ts = timespec(); clock_gettime(CLOCK_MONOTONIC_RAW, &ts)
        let start = UInt64(ts.tv_sec) * 1_000_000_000 + UInt64(ts.tv_nsec)
        defer {
            var te = timespec(); clock_gettime(CLOCK_MONOTONIC_RAW, &te)
            totalNanos += UInt64(te.tv_sec) * 1_000_000_000 + UInt64(te.tv_nsec) - start
            count += 1
        }
        return try await inner.sample(at: instant)
    }

    func reset() { let i = inner; Task { await i.reset() } }
    func avgMs() -> Double { count == 0 ? 0 : Double(totalNanos) / Double(count) / 1e6 }
}

func cpuSeconds() -> Double {
    var ru = rusage()
    getrusage(RUSAGE_SELF, &ru)
    func s(_ t: timeval) -> Double { Double(t.tv_sec) + Double(t.tv_usec) / 1e6 }
    return s(ru.ru_utime) + s(ru.ru_stime)
}

/// Fake source with N processes; every 10th is "restricted".
struct SyntheticSource: ProcessSource {
    let n: Int
    func allPIDs() throws -> [pid_t] { (1...n).map { pid_t($0) } }
    func allPIDs(into buffer: inout [pid_t]) throws {
        if buffer.count != n { buffer = (1...n).map { pid_t($0) } }
    }
    func taskAllInfo(_ pid: pid_t) throws -> TaskAllInfo {
        TaskAllInfo(pid: pid, ppid: 1, uid: pid % 10 == 0 ? 0 : 501, name: "proc\(pid)", startTime: UInt64(pid) * 1000,
                    flags: 0, status: 0, threadCount: pid % 10 == 0 ? 0 : 4, isTranslated: false)
    }
    func rusage(_ pid: pid_t) throws -> ResourceUsage {
        if pid % 10 == 0 { throw SourceError("proc_pid_rusage", errno: EPERM) }
        var ticks = UInt64(clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW))
        ticks &+= UInt64(pid)
        return ResourceUsage(userTime: ticks, systemTime: 0, physFootprint: 1 << 20, diskBytesRead: ticks,
                             diskBytesWritten: ticks, billedEnergy: 0, interruptWakeups: ticks / 1000,
                             packageIdleWakeups: 0, startAbsTime: UInt64(pid) * 1000)
    }
    func path(_ pid: pid_t) throws -> String { "/usr/bin/proc\(pid)" }
    func procArgs(_ pid: pid_t) throws -> [UInt8] { [] }
}

func runLive(seconds: Int, only: Set<String>) async {
    func on(_ n: String) -> Bool { only.isEmpty || only.contains(n) }
    let host = LiveHostSource()
    let ioreg = LiveIORegistrySource()
    let cpu = TimedCollector(CPUCollector(source: host))
    let mem = TimedCollector(MemoryCollector(source: host))
    let throttle = ProcessInfo.processInfo.environment["PROCLENS_IDLE_THROTTLE"] == "1"
    let proc = TimedCollector(ProcessCollector(source: LiveProcessSource(), idleThrottling: throttle))
    let gpu = TimedCollector(GPUCollector(source: ioreg))
    let disk = TimedCollector(DiskCollector(source: ioreg))
    let net = TimedCollector(NetworkCollector(source: LiveNetworkSource()))
    let sampler = Sampler(interval: .oneSecond, cpu: on("cpu") ? cpu : nil, memory: on("memory") ? mem : nil,
                          processes: on("processes") ? proc : nil, gpu: on("gpu") ? gpu : nil,
                          disk: on("disk") ? disk : nil, network: on("network") ? net : nil)
    _ = await sampler.tickOnce()  // warm-up (first tick builds caches)
    _ = await sampler.tickOnce()
    let c0 = cpuSeconds()
    let w0 = Date()
    await sampler.start()
    try? await Task.sleep(for: .seconds(seconds))
    await sampler.stop()
    let wall = Date().timeIntervalSince(w0)
    let used = cpuSeconds() - c0
    let table = (await sampler.tickOnce()).processes?.processes.count ?? 0
    print(String(format: "live: %d s, %d processes, CPU %.3f%% (getrusage self, %.3f cpu-s / %.1f wall-s)",
                 seconds, table, used / wall * 100, used, wall))
    print("avg ms/tick (inside collector.sample):")
    for (name, ms) in [("cpu", await cpu.avgMs()), ("memory", await mem.avgMs()), ("processes", await proc.avgMs()),
                       ("gpu", await gpu.avgMs()), ("disk", await disk.avgMs()), ("network", await net.avgMs())] {
        print(String(format: "  %-10@ %.3f ms  (%.3f%% of a core at 1 Hz)", name as NSString, ms, ms / 10))
    }
}

func runSynthetic(ticks: Int) async {
    let c = ProcessCollector(source: SyntheticSource(n: 2000))
    let clock = ContinuousClock()
    let t0 = clock.now
    _ = try? await c.sample(at: t0)
    var total = 0.0
    var worst = 0.0
    for i in 1...ticks {
        let a = clock.now
        _ = try? await c.sample(at: t0.advanced(by: .seconds(i)))
        let d = a.duration(to: clock.now)
        let ms = Double(d.components.seconds) * 1e3 + Double(d.components.attoseconds) / 1e15
        total += ms; worst = max(worst, ms)
    }
    print(String(format: "synthetic: 2000 processes (10%% restricted), %d ticks: avg %.3f ms/tick, worst %.3f ms",
                 ticks, total / Double(ticks), worst))
}

let args = CommandLine.arguments
let mode = args.count > 1 ? args[1] : "live"
let n = args.count > 2 ? Int(args[2]) ?? 20 : 20
switch mode {
case "synthetic": await runSynthetic(ticks: n)
default: await runLive(seconds: n, only: Set(args.dropFirst(3)))
}
