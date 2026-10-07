import Testing
import Darwin
@testable import ProcLensCore

struct ProcessCollectorTests {
    let t0 = ContinuousClock.Instant.now

    @Test func cpuAndDiskRates() async throws {
        let src = MockProcessSource()
        src.set(MockProcessSource.entry(pid: 10, cpuNanos: 1_000_000_000, read: 1000, written: 0, wakeups: 100))
        let c = ProcessCollector(source: src)
        let first = try await c.sample(at: t0)
        let id = ProcessID(pid: 10, startTime: 1_000)
        #expect(first.processes[id]?.cpu == 0)
        src.update(10) { e in
            e.usage?.userTime = 1_500_000_000  // +0.5 s CPU over 2 s
            e.usage?.diskBytesRead = 3000
            e.usage?.diskBytesWritten = 4000
            e.usage?.interruptWakeups = 300
        }
        let second = try await c.sample(at: t0.advanced(by: .seconds(2)))
        let s = try #require(second.processes[id])
        #expect(abs(s.cpu - 0.25) < 1e-9)
        #expect(abs(s.diskReadPerSec - 1000) < 1e-9)
        #expect(abs(s.diskWritePerSec - 2000) < 1e-9)
        #expect(abs(s.energy - (100 * 0.25 + 0.05 * 100)) < 1e-9)
        #expect(s.memory == 4096)
        #expect(!s.isRestricted)
    }

    @Test func pidReuseResetsCounters() async throws {
        let src = MockProcessSource()
        src.set(MockProcessSource.entry(pid: 10, start: 1_000, cpuNanos: 9_000_000_000))
        let c = ProcessCollector(source: src)
        _ = try await c.sample(at: t0)
        // Same pid, new start time, small counters: must not produce a negative/huge rate.
        src.set(MockProcessSource.entry(pid: 10, start: 2_000, cpuNanos: 100_000_000))
        let t = try await c.sample(at: t0.advanced(by: .seconds(1)))
        let s = try #require(t.processes[ProcessID(pid: 10, startTime: 2_000)])
        #expect(s.cpu == 0)
        #expect(t.processes[ProcessID(pid: 10, startTime: 1_000)] == nil)
    }

    @Test func vanishedProcessPruned() async throws {
        let src = MockProcessSource()
        src.set(MockProcessSource.entry(pid: 10, cpuNanos: 0))
        src.set(MockProcessSource.entry(pid: 11, cpuNanos: 0))
        let c = ProcessCollector(source: src)
        _ = try await c.sample(at: t0)
        src.remove(11)
        let t1 = try await c.sample(at: t0.advanced(by: .seconds(1)))
        #expect(t1.processes.count == 1)
        // Reappears with the same identity: treated as brand new (no stale delta).
        src.set(MockProcessSource.entry(pid: 11, cpuNanos: 5_000_000_000))
        let t2 = try await c.sample(at: t0.advanced(by: .seconds(2)))
        #expect(t2.processes[ProcessID(pid: 11, startTime: 1_000)]?.cpu == 0)
    }

    @Test func epermMarksRestricted() async throws {
        let src = MockProcessSource()
        var e = MockProcessSource.entry(pid: 20)
        e.usageError = SourceError("proc_pid_rusage", errno: EPERM)
        src.set(e)
        var f = MockProcessSource.entry(pid: 21)
        f.info.threadCount = 0  // short-info fallback shape
        src.set(f)
        let c = ProcessCollector(source: src)
        let t = try await c.sample(at: t0)
        #expect(t.processes[ProcessID(pid: 20, startTime: 1_000)]?.isRestricted == true)
        #expect(t.processes[ProcessID(pid: 20, startTime: 1_000)]?.memory == 0)
        #expect(t.processes[ProcessID(pid: 21, startTime: 1_000)]?.isRestricted == true)
    }

    @Test func esrchSkipped() async throws {
        let src = MockProcessSource()
        var gone = MockProcessSource.entry(pid: 30)
        gone.infoError = SourceError("proc_pidinfo", errno: ESRCH)
        src.set(gone)
        var gone2 = MockProcessSource.entry(pid: 31)
        gone2.usageError = SourceError("proc_pid_rusage", errno: ESRCH)
        src.set(gone2)
        src.set(MockProcessSource.entry(pid: 32))
        let t = try await ProcessCollector(source: src).sample(at: t0)
        #expect(t.processes.count == 1)
        #expect(t.processes.keys.first?.pid == 32)
    }

    @Test func pathCachedAndArgumentsOnDemand() async throws {
        let src = MockProcessSource()
        var e = MockProcessSource.entry(pid: 40, name: "sleep")
        e.args = buildProcArgs(exec: Array("/bin/sleep".utf8), args: [Array("sleep".utf8)], env: [])
        src.set(e)
        let c = ProcessCollector(source: src)
        for i in 0..<3 { _ = try await c.sample(at: t0.advanced(by: .seconds(i))) }
        #expect(src.pathCalls == 1)
        #expect(src.procArgsCalls == 0)
        let a = try await c.arguments(for: ProcessID(pid: 40, startTime: 1_000))
        #expect(a.arguments == ["sleep"])
        #expect(src.procArgsCalls == 1)
    }

    @Test func resetDropsDeltaState() async throws {
        let src = MockProcessSource()
        src.set(MockProcessSource.entry(pid: 50, cpuNanos: 0))
        let c = ProcessCollector(source: src)
        _ = try await c.sample(at: t0)
        await c.reset()
        src.update(50) { $0.usage?.userTime = 5_000_000_000 }
        let t = try await c.sample(at: t0.advanced(by: .seconds(1)))
        #expect(t.processes.values.first?.cpu == 0)
    }

    @Test func samplerFillsProcesses() async throws {
        let src = MockProcessSource()
        src.set(MockProcessSource.entry(pid: 60))
        let sampler = Sampler(processes: ProcessCollector(source: src))
        let snap = await sampler.tickOnce()
        #expect(snap.processes?.processes.count == 1)
    }

    @Test func accessiblePidIsOneRusageCallPerTick() async throws {
        let src = MockProcessSource()
        src.set(MockProcessSource.entry(pid: 70))
        let c = ProcessCollector(source: src)
        _ = try await c.sample(at: t0)
        src.resetCounts()
        // Staggered thread refresh: 1 rusage per tick plus at most one thread call per 5 ticks.
        for i in 1...10 { _ = try await c.sample(at: t0.advanced(by: .seconds(i))) }
        #expect(src.rusageCalls == 10)
        #expect(src.infoCalls == 0)
        #expect(src.threadCalls == 2)
    }

    @Test func threadCountRefreshesOnCadence() async throws {
        let src = MockProcessSource()
        src.set(MockProcessSource.entry(pid: 71))
        let c = ProcessCollector(source: src)
        _ = try await c.sample(at: t0)
        src.update(71) { $0.info.threadCount = 9 }
        var seenStale = false, seenFresh = false
        for i in 1...5 {
            let t = try await c.sample(at: t0.advanced(by: .seconds(i)))
            let n = try #require(t.processes.values.first).threadCount
            if n == 2 { seenStale = true }
            if n == 9 { seenFresh = true }
        }
        #expect(seenStale && seenFresh)
    }

    @Test func restrictedPidNotRequeriedAndRevalidated() async throws {
        let src = MockProcessSource()
        var e = MockProcessSource.entry(pid: 80)
        e.usageError = SourceError("proc_pid_rusage", errno: EPERM)
        e.info.threadCount = 0
        src.set(e)
        let c = ProcessCollector(source: src)
        _ = try await c.sample(at: t0)
        src.resetCounts()
        for i in 1...20 { _ = try await c.sample(at: t0.advanced(by: .seconds(i))) }
        #expect(src.rusageCalls == 0)
        #expect(src.infoCalls == 0)
        #expect(src.shortCalls == 2)  // every 10th tick
        // pid reused by a different process (new ppid): detected by the revalidation, full re-read.
        src.update(80) { $0.info.ppid = 77; $0.info.startTime = 5_000 }
        var found = false
        for i in 21...40 {
            let t = try await c.sample(at: t0.advanced(by: .seconds(i)))
            if t.processes[ProcessID(pid: 80, startTime: 5_000)] != nil { found = true }
        }
        #expect(found)
    }

    @Test func pidReuseDetectedViaRusageStartTime() async throws {
        let src = MockProcessSource()
        src.set(MockProcessSource.entry(pid: 90, start: 1_000, name: "old"))
        let c = ProcessCollector(source: src)
        _ = try await c.sample(at: t0)
        src.set(MockProcessSource.entry(pid: 90, start: 3_000, name: "new"))
        let t = try await c.sample(at: t0.advanced(by: .seconds(1)))
        #expect(t.processes.count == 1)
        #expect(t.processes[ProcessID(pid: 90, startTime: 3_000)]?.name == "new")
    }

    @Test func idleThrottlingHalvesReadsAndKeepsRatesExact() async throws {
        let src = MockProcessSource()
        src.set(MockProcessSource.entry(pid: 100))
        let c = ProcessCollector(source: src, idleThrottling: true)
        for i in 0..<6 { _ = try await c.sample(at: t0.advanced(by: .seconds(i))) }  // builds the idle streak
        src.resetCounts()
        for i in 6..<16 { _ = try await c.sample(at: t0.advanced(by: .seconds(i))) }
        #expect(src.rusageCalls == 5)
        // Activity is picked up on the next real read, with the rate over the real interval.
        src.update(100) { $0.usage?.userTime = 4_000_000_000 }
        var peak = 0.0
        for i in 16..<18 {
            let t = try await c.sample(at: t0.advanced(by: .seconds(i)))
            peak = max(peak, t.processes.values.first?.cpu ?? 0)
        }
        #expect(abs(peak - 4.0 / 2.0) < 1e-9 || abs(peak - 4.0) < 1e-9)
    }
}
