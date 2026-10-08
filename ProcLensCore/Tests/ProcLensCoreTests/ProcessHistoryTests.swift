import Foundation
import Testing
@testable import ProcLensCore

@Suite struct ProcessHistoryTests {
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)  // multiple of 10

    @Test func fineSeriesKeepsOneSecondResolutionForTenMinutes() async {
        let h = ProcessHistory()
        for s in 0..<900 {
            await h.record(Synth.snapshot(cpu: Double(s % 100) / 100), at: t0.addingTimeInterval(Double(s)))
        }
        let series = await h.systemSeries(metric: .cpu)
        // Last 600 s at 1 s, older part as 10 s buckets (30 of them, since 899-600=299 s => buckets 0..28 + partial).
        let last = series.suffix(601)
        #expect(zip(last, last.dropFirst()).allSatisfy { $1.0.timeIntervalSince($0.0) == 1 })
        let older = series.dropLast(601)
        #expect(!older.isEmpty)
        #expect(zip(older, older.dropFirst()).allSatisfy { $1.0.timeIntervalSince($0.0) == 10 })
        let range = t0.addingTimeInterval(890)...t0.addingTimeInterval(899)
        let ranged = await h.systemSeries(metric: .cpu, range: range)
        #expect(ranged.count == 10)
    }

    @Test func oneHourWindowIsPruned() async {
        let h = ProcessHistory()
        for s in stride(from: 0, to: 7200, by: 1) {
            await h.record(Synth.snapshot(), at: t0.addingTimeInterval(Double(s)))
        }
        let covered = await h.coveredRange()!
        #expect(covered.upperBound.timeIntervalSince(covered.lowerBound) <= 3600 + 10)
        #expect(covered.upperBound.timeIntervalSince(covered.lowerBound) >= 3500)
        let series = await h.systemSeries(metric: .cpu)
        #expect(series.count <= 600 + 361)
    }

    @Test func coarseBucketAveragesAndSpikesUsePeak() async {
        let h = ProcessHistory()
        // First bucket: cpu 0.1 x9, one 1 s spike of 0.9 -> avg 0.18, peak 0.9. Then 700 calm seconds so it leaves the fine tier.
        for s in 0..<710 {
            let cpu = s == 4 ? 0.9 : 0.1
            await h.record(Synth.snapshot(cpu: cpu), at: t0.addingTimeInterval(Double(s)))
        }
        let series = await h.systemSeries(metric: .cpu, range: t0...t0.addingTimeInterval(9))
        #expect(series.count == 1)
        #expect(abs(series[0].1 - 0.18) < 1e-9)
        let spikes = await h.spikes(metric: .cpu, threshold: 0.8)
        #expect(spikes == [t0])
        #expect(await h.spikes(metric: .cpu, threshold: 0.95).isEmpty)
        #expect(await h.spikes(metric: .cpu, threshold: 0.8, in: t0.addingTimeInterval(20)...t0.addingTimeInterval(100)).isEmpty)
    }

    @Test func missingComponentsAreSkipped() async {
        let h = ProcessHistory()
        await h.record(Synth.snapshot(cpu: nil, memoryUsed: 1 << 30, gpu: 0.5), at: t0)
        #expect(await h.systemSeries(metric: .cpu).isEmpty)
        #expect(await h.systemSeries(metric: .gpu).count == 1)
        #expect(await h.systemSeries(metric: .memory).first?.1 == Double(1 << 30))
        #expect(await h.systemSeries(metric: .disk).isEmpty)
    }

    @Test func topProcessesKeepsTop20ByCpuAndMemoryOnly() async {
        let h = ProcessHistory()
        for s in 0..<10 {
            // 100 processes: pid i has cpu i/100 (highest pids busiest), memory (100 - i) MB (lowest pids biggest).
            let procs = (1...100).map { Synth.process($0, cpu: Double($0) / 100, memory: UInt64(101 - $0) << 20) }
            await h.record(Synth.snapshot(processes: Synth.table(procs)), at: t0.addingTimeInterval(Double(s)))
        }
        let byCPU = await h.topProcesses(at: t0.addingTimeInterval(5), by: .cpu)
        #expect(byCPU.count == 20)
        #expect(byCPU.first?.id.pid == 100)
        #expect(Set(byCPU.map(\.id.pid)) == Set(81...100))
        let byMem = await h.topProcesses(at: t0.addingTimeInterval(5), by: .memory)
        #expect(Set(byMem.map(\.id.pid)) == Set(1...20))
        #expect(byMem.first?.memory == 100 << 20)
        // A process in neither top list was not stored.
        let id50 = ProcessID(pid: 50, startTime: 1_050)
        #expect(await h.series(for: id50).isEmpty)
    }

    @Test func cpuIsMeanAndMemoryIsMaxWithinBucket() async {
        let h = ProcessHistory()
        for s in 0..<10 {
            let p = Synth.process(1, cpu: s == 0 ? 1.0 : 0.0, memory: UInt64(s + 1) << 20, name: "worker")
            await h.record(Synth.snapshot(processes: Synth.table([p])), at: t0.addingTimeInterval(Double(s)))
        }
        await h.record(Synth.snapshot(), at: t0.addingTimeInterval(10))  // closes the bucket
        let top = await h.topProcesses(at: t0.addingTimeInterval(3), by: .cpu)
        #expect(top.count == 1)
        #expect(top[0].name == "worker")
        #expect(abs(top[0].cpu - 0.1) < 1e-6)
        #expect(top[0].memory == 10 << 20)
    }

    @Test func topProcessesPicksNearestBucketAndSpikeQueryWorkflow() async {
        let h = ProcessHistory()
        for s in 0..<120 {
            let burning = (50..<60).contains(s)
            let procs = [Synth.process(1, cpu: burning ? 3.5 : 0.01, memory: 1 << 20, name: "burner"),
                         Synth.process(2, cpu: 0.05, memory: 1 << 20, name: "idle")]
            await h.record(Synth.snapshot(cpu: burning ? 0.9 : 0.1, processes: Synth.table(procs)),
                           at: t0.addingTimeInterval(Double(s)))
        }
        let spikes = await h.spikes(metric: .cpu, threshold: 0.5)
        #expect(spikes == [t0.addingTimeInterval(50)])
        let top = await h.topProcesses(at: spikes[0], by: .cpu)
        #expect(top.first?.name == "burner")
        // A time far outside the data maps to the nearest bucket instead of failing.
        let far = await h.topProcesses(at: t0.addingTimeInterval(10_000), by: .cpu)
        #expect(!far.isEmpty)
        #expect(await ProcessHistory().topProcesses(at: t0, by: .cpu).isEmpty)
        let series = await h.series(for: ProcessID(pid: 1, startTime: 1_001))
        #expect(series.count == 12)
        #expect(series.first { $0.date == t0.addingTimeInterval(50) }?.cpu ?? 0 > 3)
    }

    @Test func outOfOrderTicksAreIgnored() async {
        let h = ProcessHistory()
        await h.record(Synth.snapshot(), at: t0.addingTimeInterval(5))
        await h.record(Synth.snapshot(), at: t0.addingTimeInterval(4))
        #expect(await h.systemSeries(metric: .cpu).count == 1)
    }

    /// Feeds one hour at 1 s with ~1,050 processes and checks the estimate against the 6 MB budget.
    @Test func memoryStaysUnderSixMegabytesForAnHourOf1050Processes() async {
        // A few pre-built tables with shifting hot sets, reused to keep the test fast.
        let tables: [ProcessTable] = (0..<8).map { v in
            Synth.table((1...1050).map { i in
                let hot = (i + v * 131) % 1050 < 60
                return Synth.process(i, cpu: hot ? 0.5 + Double(i % 7) / 10 : Double(i % 13) / 1000,
                                     memory: UInt64(1 + (i * 7 + v) % 900) << 20, name: "process-name-number-\(i % 400)")
            })
        }
        let h = ProcessHistory()
        var peak = 0
        for s in 0..<3700 {
            await h.record(Synth.snapshot(processes: tables[(s / 10) % tables.count]), at: t0.addingTimeInterval(Double(s)))
            if s % 250 == 0 { peak = max(peak, await h.estimatedMemoryBytes()) }
        }
        let final = await h.estimatedMemoryBytes()
        peak = max(peak, final)
        print("ProcessHistory estimate: final \(final / 1024) KB, peak \(peak / 1024) KB for 1 h x 1,050 processes")
        #expect(peak < 6 * 1024 * 1024)
        let covered = await h.coveredRange()!
        #expect(covered.upperBound.timeIntervalSince(covered.lowerBound) >= 3500)
    }
}
