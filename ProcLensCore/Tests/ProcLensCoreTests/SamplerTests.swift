import Testing
@testable import ProcLensCore

actor MockCPUCollector: Collector {
    nonisolated let id = CollectorID("mock.cpu")
    nonisolated let cost: CollectorCost
    private(set) var sampleCalls = 0
    private(set) var resetCalls = 0
    private let shouldThrow: Bool

    struct Failure: Error {}

    init(cost: CollectorCost = .perTick, shouldThrow: Bool = false) {
        self.cost = cost
        self.shouldThrow = shouldThrow
    }

    func sample(at instant: ContinuousClock.Instant) async throws -> CPUSample {
        sampleCalls += 1
        if shouldThrow { throw Failure() }
        return CPUSample(cores: [CPUCoreSample(index: 0, kind: .performance, user: 0.25, system: 0.25)])
    }

    func reset() { resetCalls += 1 }
}

struct SamplerTests {
    @Test func perTickRunsEveryTick() async {
        let cpu = MockCPUCollector()
        let sampler = Sampler(cpu: cpu)
        for _ in 0..<3 { _ = await sampler.tickOnce() }
        #expect(await cpu.sampleCalls == 3)
    }

    @Test func everyNCadence() async {
        let cpu = MockCPUCollector(cost: .everyN(3))
        let sampler = Sampler(cpu: cpu)
        var present: [Bool] = []
        for _ in 0..<7 { present.append(await sampler.tickOnce().cpu != nil) }
        #expect(present == [true, false, false, true, false, false, true])
        #expect(await cpu.sampleCalls == 3)
    }

    @Test func onDemandNeverRuns() async {
        let cpu = MockCPUCollector(cost: .onDemand)
        let sampler = Sampler(cpu: cpu)
        let snap = await sampler.tickOnce()
        #expect(snap.cpu == nil)
        #expect(await cpu.sampleCalls == 0)
    }

    @Test func failingCollectorYieldsNilAndTicksContinue() async {
        let cpu = MockCPUCollector(shouldThrow: true)
        let sampler = Sampler(cpu: cpu)
        let a = await sampler.tickOnce()
        let b = await sampler.tickOnce()
        #expect(a.cpu == nil && b.cpu == nil)
        #expect(b.tick == a.tick + 1)
        #expect(await cpu.sampleCalls == 2)
        #expect(await sampler.recentHistory().count == 2)
    }

    @Test func historyCapacityFollowsInterval() async {
        let sampler = Sampler(interval: .fiveSeconds)
        for _ in 0..<20 { _ = await sampler.tickOnce() }
        #expect(await sampler.recentHistory().count == 12)
    }

    @Test func setIntervalResetsCollectorsAndResizesHistory() async {
        let cpu = MockCPUCollector()
        let sampler = Sampler(interval: .oneSecond, cpu: cpu)
        for _ in 0..<5 { _ = await sampler.tickOnce() }
        await sampler.setInterval(.fiveSeconds)
        #expect(await cpu.resetCalls == 1)
        #expect(await sampler.recentHistory().count == 5)
        for _ in 0..<20 { _ = await sampler.tickOnce() }
        #expect(await sampler.recentHistory().count == 12)
        await sampler.setInterval(.fiveSeconds) // unchanged: no reset
        #expect(await cpu.resetCalls == 1)
    }

    @Test func startDeliversSnapshotsThenStops() async {
        let cpu = MockCPUCollector()
        let sampler = Sampler(interval: .halfSecond, cpu: cpu)
        await sampler.start()
        var received: [SystemSnapshot] = []
        for await snapshot in sampler.snapshots {
            received.append(snapshot)
            if received.count >= 2 { break }
        }
        await sampler.stop()
        #expect(received.count == 2)
        #expect(received[1].tick > received[0].tick)
        #expect(received[0].cpu != nil)
        #expect(await sampler.isRunning == false)
        let calls = await cpu.sampleCalls
        try? await Task.sleep(for: .milliseconds(700))
        #expect(await cpu.sampleCalls == calls)
    }
}

@Test func runningSamplerDeallocatesAndFinishesStream() async throws {
    var sampler: Sampler? = Sampler(interval: .halfSecond)
    let stream = sampler!.snapshots
    await sampler!.start()
    weak let weakSampler = sampler
    sampler = nil
    // Draining the stream must end once the Sampler is gone.
    for await _ in stream {}
    #expect(weakSampler == nil)
}
