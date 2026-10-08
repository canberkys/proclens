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

/// Listening-port scan cost: live machine (cold = first scan, warm = negative cache populated) and a
/// synthetic 1,000-process table (every 10th process listens, 1 in 20 restricted).
///   swift run -c release --package-path ProcLensCore ProcLensBench ports [runs]
struct SyntheticFDSource: FDSource {
    func listFDs(pid: pid_t) throws -> [FDEntry] {
        pid % 10 == 0 ? [FDEntry(fd: 0, type: .vnode), FDEntry(fd: 3, type: .socket), FDEntry(fd: 4, type: .socket)]
                      : [FDEntry(fd: 0, type: .vnode), FDEntry(fd: 1, type: .vnode), FDEntry(fd: 2, type: .pipe)]
    }
    func vnodeInfo(pid: pid_t, fd: Int32) throws -> RawVnodeInfo { RawVnodeInfo(path: "/dev/null", openFlags: 1) }
    func socketInfo(pid: pid_t, fd: Int32) throws -> RawSocketInfo {
        fd == 3 ? RawSocketInfo(kind: .tcp, family: AF_INET, proto: IPPROTO_TCP, localAddress: [0, 0, 0, 0],
                                remoteAddress: [0, 0, 0, 0], localPort: UInt16(truncatingIfNeeded: 10_000 + pid), tcpState: 1)
                 : RawSocketInfo(kind: .inet, family: AF_INET, proto: IPPROTO_UDP, localAddress: [127, 0, 0, 1],
                                 remoteAddress: [127, 0, 0, 1], localPort: 5353, remotePort: 5353)
    }
    func pipeInfo(pid: pid_t, fd: Int32) throws -> RawPipeInfo { RawPipeInfo(handle: 1, peerHandle: 2) }
}

func millis(_ d: Duration) -> Double { Double(d.components.seconds) * 1e3 + Double(d.components.attoseconds) / 1e15 }

func runPorts(runs: Int) async {
    let clock = ContinuousClock()
    // Synthetic 1,000 processes.
    var procs: [ProcessID: ProcessSample] = [:]
    for pid in 1...1000 {
        let id = ProcessID(pid: pid_t(pid), startTime: UInt64(pid) * 1000)
        procs[id] = ProcessSample(id: id, ppid: 1, uid: 501, name: "p\(pid)", path: nil, threadCount: 1, isTranslated: false,
                                  cpu: 0, memory: 0, diskReadPerSec: 0, diskWritePerSec: 0, energy: 0, isRestricted: pid % 20 == 0)
    }
    let synthetic = ListeningPortCollector(source: SyntheticFDSource())
    let table = ProcessTable(processes: procs)
    var t0 = clock.now
    let cold = await synthetic.scan(table: table)
    let coldMs = millis(t0.duration(to: clock.now))
    t0 = clock.now
    for _ in 0..<runs { _ = await synthetic.scan(table: table) }
    let warm = millis(t0.duration(to: clock.now)) / Double(runs)
    print(String(format: "ports synthetic: 1000 processes (mock syscalls, %d ports): cold %.3f ms, warm avg %.3f ms", cold.count, coldMs, warm))

    // Live machine.
    let pc = ProcessCollector(source: LiveProcessSource())
    _ = try? await pc.sample(at: clock.now)
    guard let live = try? await pc.sample(at: clock.now.advanced(by: .seconds(1))) else { return }
    let collector = ListeningPortCollector()
    t0 = clock.now
    let liveCold = await collector.scan(table: live)
    let liveColdMs = millis(t0.duration(to: clock.now))
    var worst = 0.0, total = 0.0
    for _ in 0..<runs {
        let a = clock.now
        _ = await collector.scan(table: live)
        let ms = millis(a.duration(to: clock.now)); total += ms; worst = max(worst, ms)
    }
    print(String(format: "ports live: %d processes (%d restricted), %d ports: cold %.3f ms, warm avg %.3f ms, worst %.3f ms",
                 live.processes.count, live.processes.values.filter(\.isRestricted).count, liveCold.count,
                 liveColdMs, total / Double(runs), worst))
}

let args = CommandLine.arguments
let mode = args.count > 1 ? args[1] : "live"
let n = args.count > 2 ? Int(args[2]) ?? 20 : 20
switch mode {
case "synthetic": await runSynthetic(ticks: n)
case "ports": await runPorts(runs: args.count > 2 ? n : 50)
default: await runLive(seconds: n, only: Set(args.dropFirst(3)))
}
