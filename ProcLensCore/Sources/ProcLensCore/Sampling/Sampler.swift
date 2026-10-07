/// Drives all scheduled collectors on one deadline-based loop and publishes snapshots.
///
/// `snapshots` is created once and lives as long as the Sampler: `stop()` pauses the
/// loop but does not finish the stream, so `start()` can be called again. The stream
/// finishes when the Sampler is deallocated. Buffering is newest-1, so slow consumers
/// skip ticks rather than queue them.
public actor Sampler {
    public nonisolated let snapshots: AsyncStream<SystemSnapshot>

    private let continuation: AsyncStream<SystemSnapshot>.Continuation
    private let clock: ContinuousClock
    private let cpu: (any Collector<CPUSample>)?
    private let memory: (any Collector<MemorySample>)?
    private let processes: (any Collector<ProcessTable>)?

    private var interval: SamplingInterval
    private var history: RingBuffer<SystemSnapshot>
    private var tick: UInt64 = 0
    private var loop: Task<Void, Never>?

    public init(
        interval: SamplingInterval = .oneSecond,
        cpu: (any Collector<CPUSample>)? = nil,
        memory: (any Collector<MemorySample>)? = nil,
        processes: (any Collector<ProcessTable>)? = nil,
        clock: ContinuousClock = .init()
    ) {
        self.interval = interval
        self.cpu = cpu
        self.memory = memory
        self.processes = processes
        self.clock = clock
        self.history = RingBuffer(capacity: Self.historyCapacity(for: interval))
        let (stream, continuation) = AsyncStream<SystemSnapshot>.makeStream(bufferingPolicy: .bufferingNewest(1))
        self.snapshots = stream
        self.continuation = continuation
    }

    deinit {
        loop?.cancel()
        continuation.finish()
    }

    public var isRunning: Bool { loop != nil }

    /// Starts the sampling loop. No-op if already running.
    public func start() {
        guard loop == nil else { return }
        // Re-acquire `self` weakly every tick so a running Sampler can still deallocate.
        loop = Task { [weak self, clock] in
            var deadline = clock.now
            while !Task.isCancelled {
                guard let period = await self?.tickForLoop() else { return }
                deadline = deadline.advanced(by: period)
                let now = clock.now
                if deadline < now { deadline = now.advanced(by: period) }
                do { try await clock.sleep(until: deadline) } catch { return }
            }
        }
    }

    /// Pauses the loop. The stream stays open; call `start()` to resume.
    public func stop() {
        loop?.cancel()
        loop = nil
    }

    /// Changes the cadence: resets every collector's delta state and resizes history.
    public func setInterval(_ newInterval: SamplingInterval) async {
        guard newInterval != interval else { return }
        let wasRunning = loop != nil
        stop()
        interval = newInterval
        let kept = history.elements
        history = RingBuffer(capacity: Self.historyCapacity(for: newInterval))
        for snapshot in kept.suffix(history.capacity) { history.append(snapshot) }
        await cpu?.reset()
        await memory?.reset()
        await processes?.reset()
        if wasRunning { start() }
    }

    /// Runs one tick without the loop (also used by tests).
    public func tickOnce() async -> SystemSnapshot {
        let instant = clock.now
        let n = tick
        tick += 1
        async let cpuSample = Self.collect(cpu, tick: n, at: instant)
        async let memorySample = Self.collect(memory, tick: n, at: instant)
        async let processTable = Self.collect(processes, tick: n, at: instant)
        let snapshot = await SystemSnapshot(tick: n, instant: instant, cpu: cpuSample, memory: memorySample,
                                            processes: processTable)
        history.append(snapshot)
        continuation.yield(snapshot)
        return snapshot
    }

    /// Up to the last 60 seconds of snapshots, oldest first.
    public func recentHistory() -> [SystemSnapshot] { history.elements }

    // MARK: - Private

    /// One loop iteration; returns the period to wait before the next tick.
    private func tickForLoop() async -> Duration {
        _ = await tickOnce()
        return interval.duration
    }

    private static func historyCapacity(for interval: SamplingInterval) -> Int {
        max(1, Int(60 / interval.rawValue))
    }

    private static func isDue(_ cost: CollectorCost, tick: UInt64) -> Bool {
        switch cost {
        case .perTick: true
        case .everyN(let n): n > 0 && tick % UInt64(n) == 0
        case .onDemand: false
        }
    }

    /// A throwing collector yields nil instead of aborting the tick.
    private static func collect<S: Sendable>(
        _ collector: (any Collector<S>)?, tick: UInt64, at instant: ContinuousClock.Instant
    ) async -> S? {
        guard let collector, isDue(collector.cost, tick: tick) else { return nil }
        return try? await collector.sample(at: instant)
    }
}
