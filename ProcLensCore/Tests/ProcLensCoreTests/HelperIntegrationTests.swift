import Darwin
import Foundation
import ProcLensHelperProtocol
import Testing
@testable import ProcLensCore

/// Scripted `RestrictedProcessSource`.
final class MockRestricted: RestrictedProcessSource, @unchecked Sendable {
    private let lock = NSLock()
    private var _enabled = true
    private var _usage: [Int32: HelperRusage] = [:]
    private var _threads: [Int32: Int32] = [:]
    private var _fail = false
    private var _delay: Duration = .zero
    private var _usageCalls: [[Int32]] = []

    var isEnabled: Bool { lock.withLock { _enabled } }
    func setEnabled(_ v: Bool) { lock.withLock { _enabled = v } }
    func setFail(_ v: Bool) { lock.withLock { _fail = v } }
    func setDelay(_ d: Duration) { lock.withLock { _delay = d } }
    var usageCalls: [[Int32]] { lock.withLock { _usageCalls } }
    func set(pid: Int32, cpuNanos: UInt64, startAbs: UInt64 = 7, footprint: UInt64 = 1 << 20, threads: Int32 = 4) {
        lock.withLock {
            _usage[pid] = HelperRusage(pid: pid, userTime: cpuNanos, systemTime: 0, physFootprint: footprint,
                                       diskBytesRead: 0, diskBytesWritten: 0, billedEnergy: 0, interruptWakeups: 0,
                                       packageIdleWakeups: 0, startAbsTime: startAbs)
            _threads[pid] = threads
        }
    }

    func readRusage(pids: [Int32]) async throws -> [HelperRusage] {
        let (fail, delay) = lock.withLock { () -> (Bool, Duration) in
            _usageCalls.append(pids)
            return (_fail, _delay)
        }
        if delay > .zero { try await Task.sleep(for: delay) }
        if fail { throw HelperClientError.connectionFailed("mock") }
        return lock.withLock { pids.compactMap { _usage[$0] } }
    }

    func readProcessInfo(pids: [Int32]) async throws -> [HelperProcessInfo] {
        lock.withLock {
            pids.compactMap { p in
                _threads[p].map { HelperProcessInfo(pid: p, ppid: 1, uid: 0, name: "root\(p)", path: "/usr/libexec/root\(p)",
                                                    startTime: 1_000, threadCount: $0) }
            }
        }
    }
}

struct HelperIntegrationTests {
    let t0 = ContinuousClock.Instant.now
    let id = ProcessID(pid: 20, startTime: 1_000)

    private func makeSource() -> MockProcessSource {
        let src = MockProcessSource()
        var e = MockProcessSource.entry(pid: 20)
        e.usageError = SourceError("proc_pid_rusage", errno: EPERM)
        src.set(e)
        src.set(MockProcessSource.entry(pid: 21))  // readable: never sent to the helper
        return src
    }

    @Test func mergesHelperValuesAndClearsRestricted() async throws {
        let helper = MockRestricted()
        helper.set(pid: 20, cpuNanos: 1_000_000_000)
        let c = ProcessCollector(source: makeSource(), restricted: helper)
        let first = try await c.sample(at: t0)
        #expect(first.processes[id]?.isRestricted == true)  // the helper reply lands after the tick returned
        await c.awaitHelperIdle()
        helper.set(pid: 20, cpuNanos: 1_500_000_000)
        _ = try await c.sample(at: t0.advanced(by: .seconds(1)))
        await c.awaitHelperIdle()
        let third = try await c.sample(at: t0.advanced(by: .seconds(2)))
        await c.awaitHelperIdle()
        let s = try #require(third.processes[id])
        #expect(!s.isRestricted && s.viaHelper)
        #expect(s.memory == 1 << 20)
        #expect(s.threadCount == 4)
        #expect(abs(s.cpu - 0.5) < 1e-9)  // +0.5 s CPU between the requests of ticks 0 and 1 (1 s apart)
        #expect(helper.usageCalls.allSatisfy { $0 == [20] })  // restricted pids only
        #expect(helper.usageCalls.count == 3)  // exactly one call per tick
    }

    @Test func pidReuseBetweenHelperReadsResetsCounters() async throws {
        let helper = MockRestricted()
        helper.set(pid: 20, cpuNanos: 9_000_000_000, startAbs: 7)
        let c = ProcessCollector(source: makeSource(), restricted: helper)
        for i in 0..<2 {
            _ = try await c.sample(at: t0.advanced(by: .seconds(Int64(i))))
            await c.awaitHelperIdle()
        }
        // The helper now reports another start time for pid 20 with a small counter: no negative/huge rate.
        helper.set(pid: 20, cpuNanos: 100_000_000, startAbs: 99)
        _ = try await c.sample(at: t0.advanced(by: .seconds(2)))
        await c.awaitHelperIdle()
        let t = try await c.sample(at: t0.advanced(by: .seconds(3)))
        #expect(t.processes[id]?.cpu == 0)
    }

    @Test func replyForAReusedPidIsDropped() async throws {
        let src = makeSource()
        let helper = MockRestricted()
        helper.set(pid: 20, cpuNanos: 1_000_000_000)
        helper.setDelay(.milliseconds(500))
        let c = ProcessCollector(source: src, restricted: helper)
        _ = try await c.sample(at: t0)  // request in flight for the process started at 1_000
        for i in 1..<9 { _ = try await c.sample(at: t0.advanced(by: .milliseconds(Int64(i) * 10))) }
        // The pid is reused by a different program; the 10th tick re-validates restricted pids and notices.
        var e = MockProcessSource.entry(pid: 20, start: 5_000, name: "other")
        e.usageError = SourceError("proc_pid_rusage", errno: EPERM)
        src.set(e)
        _ = try await c.sample(at: t0.advanced(by: .milliseconds(90)))
        await c.awaitHelperIdle()  // the late reply belongs to the old process: dropped
        let t = try await c.sample(at: t0.advanced(by: .milliseconds(100)))  // still inside the backoff
        let fresh = try #require(t.processes[ProcessID(pid: 20, startTime: 5_000)])
        #expect(fresh.isRestricted && !fresh.viaHelper && fresh.memory == 0)
        #expect(t.processes[id] == nil)
    }

    @Test func tickDoesNotWaitForSlowHelper() async throws {
        let helper = MockRestricted()
        helper.set(pid: 20, cpuNanos: 1)
        helper.setDelay(.seconds(1))
        let c = ProcessCollector(source: makeSource(), restricted: helper)
        let clock = ContinuousClock()
        let began = clock.now
        _ = try await c.sample(at: t0)
        #expect(began.duration(to: clock.now) < .milliseconds(200))
    }

    @Test func failingHelperBacksOffExponentiallyAndKeepsValues() async throws {
        let helper = MockRestricted()
        helper.set(pid: 20, cpuNanos: 1_000_000_000)
        let c = ProcessCollector(source: makeSource(), restricted: helper, helperMaxBackoff: .seconds(4))
        func tick(_ seconds: Double) async throws -> ProcessTable {
            let t = try await c.sample(at: t0.advanced(by: .seconds(seconds)))
            await c.awaitHelperIdle()
            return t
        }
        _ = try await tick(0)
        _ = try await tick(1)
        #expect(helper.usageCalls.count == 2)

        helper.setFail(true)
        _ = try await tick(2)  // fails -> next request allowed at +1 s
        #expect(helper.usageCalls.count == 3)
        _ = try await tick(2.5)
        #expect(helper.usageCalls.count == 3)  // backing off
        _ = try await tick(3)  // fails again -> +2 s
        #expect(helper.usageCalls.count == 4)
        _ = try await tick(4)
        #expect(helper.usageCalls.count == 4)
        _ = try await tick(5)  // third failure -> +4 s (the cap)
        #expect(helper.usageCalls.count == 5)
        for s in [6.0, 7.0, 8.0] { _ = try await tick(s) }
        #expect(helper.usageCalls.count == 5)
        helper.setFail(false)
        _ = try await tick(9)
        #expect(helper.usageCalls.count == 6)
        let t = try await tick(10)  // recovered: asks every tick again
        #expect(helper.usageCalls.count == 7)
        #expect(t.processes[id]?.memory == 1 << 20)  // last values were kept through the outage
        #expect(t.processes[id]?.isRestricted == false)
    }

    @Test func slowReplyCountsAsFailure() async throws {
        let helper = MockRestricted()
        helper.set(pid: 20, cpuNanos: 1)
        helper.setDelay(.milliseconds(260))
        let c = ProcessCollector(source: makeSource(), restricted: helper)
        _ = try await c.sample(at: t0)
        await c.awaitHelperIdle()
        _ = try await c.sample(at: t0.advanced(by: .milliseconds(500)))  // inside the 1 s backoff
        #expect(helper.usageCalls.count == 1)
        _ = try await c.sample(at: t0.advanced(by: .seconds(1)))
        await c.awaitHelperIdle()
        #expect(helper.usageCalls.count == 2)
    }

    @Test func hungHelperIsAbandonedByTimeout() async throws {
        let helper = MockRestricted()
        helper.set(pid: 20, cpuNanos: 1)
        helper.setDelay(.seconds(30))
        let c = ProcessCollector(source: makeSource(), restricted: helper, helperTimeout: .milliseconds(100))
        _ = try await c.sample(at: t0)
        try await Task.sleep(for: .milliseconds(300))
        _ = try await c.sample(at: t0.advanced(by: .seconds(2)))  // backoff over, a new request goes out
        try await Task.sleep(for: .milliseconds(50))
        #expect(helper.usageCalls.count == 2)
    }

    @Test func disablingRevertsToRestrictedAndReEnablingRecovers() async throws {
        let helper = MockRestricted()
        helper.set(pid: 20, cpuNanos: 1_000_000_000)
        let c = ProcessCollector(source: makeSource(), restricted: helper)
        for i in 0..<2 {
            _ = try await c.sample(at: t0.advanced(by: .seconds(Int64(i))))
            await c.awaitHelperIdle()
        }
        helper.setEnabled(false)
        let t = try await c.sample(at: t0.advanced(by: .seconds(2)))
        let s = try #require(t.processes[id])
        #expect(s.isRestricted && !s.viaHelper && s.memory == 0)
        helper.setEnabled(true)  // approving again takes effect without a restart
        _ = try await c.sample(at: t0.advanced(by: .seconds(3)))
        await c.awaitHelperIdle()
        let again = try await c.sample(at: t0.advanced(by: .seconds(4)))
        #expect(again.processes[id]?.isRestricted == false)
    }

    @Test func withoutHelperProcessStaysRestricted() async throws {
        let c = ProcessCollector(source: makeSource())
        let t = try await c.sample(at: t0)
        #expect(t.processes[id]?.isRestricted == true)
    }

    @Test func helperPortsMapToTableProcesses() {
        let table = treeTable([treeSample(20, ppid: 1, start: 1_000)])
        let sockets = [
            HelperListeningSocket(pid: 20, transport: .udp, localAddress: "0.0.0.0", port: 5353, isIPv6: false),
            HelperListeningSocket(pid: 20, transport: .tcp, localAddress: "127.0.0.1", port: 631, isIPv6: false),
            HelperListeningSocket(pid: 20, transport: .tcp, localAddress: "::1", port: 632, isIPv6: true),
            HelperListeningSocket(pid: 99, transport: .tcp, localAddress: "0.0.0.0", port: 1, isIPv6: false),  // not in table
        ]
        let ports = ListeningPortCollector.helperPorts(from: sockets, table: table)
        #expect(ports.map(\.port) == [5353, 631, 632])
        #expect(ports.map(\.isLoopbackOnly) == [false, true, true])
        #expect(ports.allSatisfy { $0.processID == ProcessID(pid: 20, startTime: 1_000) })
    }
}

final class MockPrivileged: PrivilegedSignaller, @unchecked Sendable {
    let isEnabled: Bool
    let controller: MockController
    private let lock = NSLock()
    private var recorded: [(pid: Int32, signal: Int32, start: UInt64)] = []
    var calls: [(pid: Int32, signal: Int32, start: UInt64)] { lock.withLock { recorded } }
    init(enabled: Bool = true, controller: MockController) { isEnabled = enabled; self.controller = controller }
    func signalProcess(pid: Int32, signal: Int32, expectedStartTime: UInt64) async throws {
        lock.withLock { recorded.append((pid, signal, expectedStartTime)) }
        _ = controller.send(SIGKILL, to: pid)
    }
}

/// Every signal fails with EPERM while the process lives (a root-owned process).
final class EpermController: ProcessController, @unchecked Sendable {
    let base: MockController
    init(base: MockController) { self.base = base }
    func startTime(pid: pid_t) -> UInt64? { base.startTime(pid: pid) }
    func send(_ signal: Int32, to pid: pid_t) -> Int32 { base.isAlive(pid: pid) ? EPERM : ESRCH }
    func isAlive(pid: pid_t) -> Bool { base.isAlive(pid: pid) }
}

struct TreeKillerPrivilegedTests {
    @Test func retriesThroughHelperOnEperm() async {
        let t = treeTable([treeSample(100, ppid: 1, name: "rootd"), treeSample(101, ppid: 100)])
        let base = MockController(alive: [100, 101])
        let priv = MockPrivileged(controller: base)
        let root = t.processes.keys.first { $0.pid == 100 }!
        let results = await TreeKiller(controller: EpermController(base: base), ownPID: 9999, privileged: priv)
            .kill(root: root, in: t, gracePeriod: .milliseconds(100), pollInterval: .milliseconds(10))
        #expect(results.map(\.outcome) == [.terminated, .terminated])
        #expect(priv.calls.map(\.pid) == [101, 100])
        #expect(priv.calls.allSatisfy { $0.signal == SIGTERM })
        #expect(priv.calls.map(\.start) == [101, 100])  // the start-time identity travels with the request
    }

    @Test func withoutHelperEpermStaysFailed() async {
        let t = treeTable([treeSample(100, ppid: 1, name: "rootd")])
        let base = MockController(alive: [100])
        let priv = MockPrivileged(enabled: false, controller: base)
        let root = t.processes.keys.first { $0.pid == 100 }!
        let results = await TreeKiller(controller: EpermController(base: base), ownPID: 9999, privileged: priv)
            .kill(root: root, in: t, gracePeriod: .milliseconds(50), pollInterval: .milliseconds(10))
        #expect(results.map(\.outcome) == [.failed(errno: EPERM)])
        #expect(priv.calls.isEmpty)
    }
}
