import Darwin
import Foundation
import Testing
@testable import ProcLensCore

func treeSample(_ pid: pid_t, ppid: pid_t, start: UInt64? = nil, name: String = "p") -> ProcessSample {
    ProcessSample(id: ProcessID(pid: pid, startTime: start ?? UInt64(pid)), ppid: ppid, uid: 501, name: name, path: nil,
                  threadCount: 1, isTranslated: false, cpu: 0, memory: 0, diskReadPerSec: 0, diskWritePerSec: 0,
                  energy: 0, isRestricted: false)
}

func treeTable(_ s: [ProcessSample]) -> ProcessTable {
    ProcessTable(processes: Dictionary(uniqueKeysWithValues: s.map { ($0.id, $0) }))
}

struct ProcessTreeTests {
    @Test func buildsRootsChildrenAndOrdering() {
        let t = treeTable([
            treeSample(1, ppid: 0, start: 1), treeSample(20, ppid: 1, start: 30), treeSample(10, ppid: 1, start: 50),
            treeSample(30, ppid: 20), treeSample(99, ppid: 555, start: 5),
        ])
        let tree = ProcessTree(table: t)
        let id = { (p: pid_t) in t.processes.keys.first { $0.pid == p }! }
        #expect(tree.roots.map(\.pid) == [1, 99])             // 1 (start 1), 99 (parent missing, start 5)
        #expect(tree.children(of: id(1)).map(\.pid) == [20, 10]) // by start time, not pid
        #expect(tree.parent(of: id(30)) == id(20))
    }

    @Test func descendantsAreBreadthFirst() {
        let t = treeTable([
            treeSample(1, ppid: 0), treeSample(2, ppid: 1), treeSample(3, ppid: 1), treeSample(4, ppid: 2),
            treeSample(5, ppid: 4), treeSample(6, ppid: 3),
        ])
        let tree = ProcessTree(table: t)
        let root = t.processes.keys.first { $0.pid == 1 }!
        #expect(tree.descendants(of: root).map(\.pid) == [2, 3, 4, 6, 5])
    }

    @Test func cycleIsSafe() {
        let t = treeTable([treeSample(1, ppid: 2, start: 1), treeSample(2, ppid: 1, start: 2), treeSample(3, ppid: 2, start: 3)])
        let tree = ProcessTree(table: t)
        #expect(tree.roots.count == 1)
        let flat = tree.flattened { _ in true }
        #expect(flat.count == 3)
        #expect(Set(flat.map(\.id.pid)) == [1, 2, 3])
    }

    @Test func selfParentIsRoot() {
        let t = treeTable([treeSample(7, ppid: 7)])
        #expect(ProcessTree(table: t).roots.map(\.pid) == [7])
    }

    @Test func reusedPidParentStartedLaterIsNotParent() {
        // Child started at 10 but "parent" pid 5 started at 100 (pid reused later): child is a root.
        let t = treeTable([treeSample(5, ppid: 0, start: 100), treeSample(6, ppid: 5, start: 10)])
        let tree = ProcessTree(table: t)
        #expect(tree.roots.count == 2)
    }

    @Test func flattenedHonorsExpansion() {
        let t = treeTable([treeSample(1, ppid: 0), treeSample(2, ppid: 1), treeSample(3, ppid: 2)])
        let tree = ProcessTree(table: t)
        #expect(tree.flattened { _ in false }.map(\.depth) == [0])
        let all = tree.flattened { _ in true }
        #expect(all.map(\.id.pid) == [1, 2, 3] && all.map(\.depth) == [0, 1, 2])
    }
}

final class MockController: ProcessController, @unchecked Sendable {
    private let lock = NSLock()
    var alive: Set<pid_t>
    var ignoreTerm: Set<pid_t>
    var sent: [(Int32, pid_t)] = []
    var startOverride: [pid_t: UInt64] = [:]

    init(alive: Set<pid_t>, ignoreTerm: Set<pid_t> = []) { self.alive = alive; self.ignoreTerm = ignoreTerm }

    func startTime(pid: pid_t) -> UInt64? { lock.withLock { alive.contains(pid) ? (startOverride[pid] ?? UInt64(pid)) : nil } }
    func send(_ signal: Int32, to pid: pid_t) -> Int32 {
        lock.withLock {
            sent.append((signal, pid))
            guard alive.contains(pid) else { return ESRCH }
            if signal == SIGKILL || !ignoreTerm.contains(pid) { alive.remove(pid) }
            return 0
        }
    }
    func isAlive(pid: pid_t) -> Bool { lock.withLock { alive.contains(pid) } }
}

struct TreeKillerTests {
    private func rootID(_ t: ProcessTable, _ pid: pid_t) -> ProcessID { t.processes.keys.first { $0.pid == pid }! }

    @Test func killsChildrenFirstAndEscalates() async {
        let t = treeTable([treeSample(100, ppid: 1, name: "server"), treeSample(101, ppid: 100), treeSample(102, ppid: 101),
                           treeSample(200, ppid: 1, name: "other")])
        let ctl = MockController(alive: [100, 101, 102, 200], ignoreTerm: [101])
        let results = await TreeKiller(controller: ctl, ownPID: 9999)
            .kill(root: rootID(t, 100), in: t, gracePeriod: .milliseconds(100), pollInterval: .milliseconds(10))
        #expect(results.map(\.id.pid) == [102, 101, 100])
        #expect(results.map(\.outcome) == [.terminated, .killed, .terminated])
        #expect(ctl.sent.prefix(3).map(\.1) == [102, 101, 100])      // SIGTERM order: deepest first
        #expect(ctl.sent.contains { $0 == (SIGKILL, 101) })
        #expect(!ctl.sent.contains { $0.1 == 200 } && ctl.isAlive(pid: 200))
    }

    @Test func rootRefusedTouchesNothing() async {
        let t = treeTable([treeSample(1, ppid: 0, name: "launchd"), treeSample(50, ppid: 1)])
        let ctl = MockController(alive: [1, 50])
        let results = await TreeKiller(controller: ctl, ownPID: 9999).kill(root: rootID(t, 1), in: t)
        #expect(results.count == 1)
        if case .refused = results[0].outcome {} else { Issue.record("expected refused") }
        #expect(ctl.sent.isEmpty)
    }

    @Test func refusedDescendantIsSkipped() async {
        let t = treeTable([treeSample(100, ppid: 1), treeSample(101, ppid: 100, name: "WindowServer")])
        let ctl = MockController(alive: [100, 101])
        let results = await TreeKiller(controller: ctl, ownPID: 9999)
            .kill(root: rootID(t, 100), in: t, gracePeriod: .milliseconds(50), pollInterval: .milliseconds(10))
        #expect(results.count == 2)
        if case .refused = results[0].outcome {} else { Issue.record("expected refused") }
        #expect(results[1].outcome == .terminated)
        #expect(ctl.isAlive(pid: 101))
    }

    @Test func reusedPidIsNotSignalled() async {
        let t = treeTable([treeSample(100, ppid: 1), treeSample(101, ppid: 100)])
        let ctl = MockController(alive: [100, 101])
        ctl.startOverride[101] = 424242      // different process now owns pid 101
        let results = await TreeKiller(controller: ctl, ownPID: 9999)
            .kill(root: rootID(t, 100), in: t, gracePeriod: .milliseconds(50), pollInterval: .milliseconds(10))
        #expect(results[0].outcome == .alreadyGone)
        #expect(ctl.isAlive(pid: 101))
    }

    /// Real processes: `sh` with two `sleep` children; everything must be gone afterwards.
    @Test func killsRealProcessTree() async throws {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/sh")
        proc.arguments = ["-c", "sleep 60 & sleep 60 & wait"]
        try proc.run()
        let shell = proc.processIdentifier
        defer { if proc.isRunning { kill(shell, SIGKILL) } }

        let source = LiveProcessSource()
        func snapshot() -> ProcessTable {
            var samples: [ProcessSample] = []
            for pid in (try? source.allPIDs()) ?? [] {
                guard let info = try? source.taskAllInfo(pid) else { continue }
                if pid == shell || info.ppid == shell || samples.contains(where: { $0.pid == info.ppid }) {
                    samples.append(treeSample(pid, ppid: info.ppid, start: info.startTime, name: info.name))
                }
            }
            return treeTable(samples)
        }
        var table = snapshot()
        for _ in 0..<60 where table.processes.count < 3 {
            try await Task.sleep(for: .milliseconds(50))
            table = snapshot()
        }
        #expect(table.processes.count == 3)
        let pids = table.processes.keys.map(\.pid)
        let root = try #require(table.processes.keys.first { $0.pid == shell })

        let results = await TreeKiller().kill(root: root, in: table, gracePeriod: .seconds(3))
        #expect(results.count == 3)
        #expect(results.last?.id == root)
        let live = LiveProcessController()
        for pid in pids { #expect(!live.isAlive(pid: pid), "pid \(pid) still alive") }
    }
}
