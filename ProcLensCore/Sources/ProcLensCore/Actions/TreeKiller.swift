import Darwin
import Foundation

/// Signals and liveness checks, behind a protocol so the escalation logic is testable.
public protocol ProcessController: Sendable {
    /// Start time (µs since epoch) of the live process with this pid, or nil when it doesn't exist.
    func startTime(pid: pid_t) -> UInt64?
    /// `kill(2)`; returns 0 or the errno.
    func send(_ signal: Int32, to pid: pid_t) -> Int32
    /// False when the process is gone or a zombie.
    func isAlive(pid: pid_t) -> Bool
}

public struct LiveProcessController: ProcessController {
    public init() {}

    public func startTime(pid: pid_t) -> UInt64? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        return info.pbi_start_tvsec &* 1_000_000 &+ info.pbi_start_tvusec
    }

    public func send(_ signal: Int32, to pid: pid_t) -> Int32 {
        kill(pid, signal) == 0 ? 0 : errno
    }

    public func isAlive(pid: pid_t) -> Bool {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        if proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size {
            return info.pbi_status != UInt32(SZOMB)
        }
        // Not readable: fall back to the signal-0 probe (EPERM still means it exists).
        return kill(pid, 0) == 0 || errno == EPERM
    }
}

public enum KillOutcome: Sendable, Hashable {
    /// Exited after SIGTERM.
    case terminated
    /// Needed SIGKILL.
    case killed
    /// Not signalled: `ProtectionPolicy` refused it.
    case refused(reason: String)
    /// Already gone, or the pid now belongs to a different process (reuse).
    case alreadyGone
    /// Signal failed (e.g. `EPERM`) or the process survived SIGKILL.
    case failed(errno: Int32)
}

public struct KillResult: Sendable, Hashable {
    public var id: ProcessID
    public var name: String
    public var outcome: KillOutcome
}

/// Ends a process and all its descendants, children first: SIGTERM, grace period, SIGKILL for survivors.
/// Algorithm idea (descendant BFS, children first) from simple-dev-server-viewer `collect_descendants` (MIT).
public actor TreeKiller {
    private let controller: any ProcessController
    private let policy: ProtectionPolicy
    private let ownPID: pid_t

    public init(controller: any ProcessController = LiveProcessController(), policy: ProtectionPolicy = ProtectionPolicy(),
                ownPID: pid_t = getpid()) {
        self.controller = controller
        self.policy = policy
        self.ownPID = ownPID
    }

    /// Kills `root` and its descendants as found in `table`. Callers must have confirmed with the user.
    /// If the root itself is refused, nothing is touched. Descendants refused by policy are skipped.
    /// Returns one result per process, in kill order (deepest first, root last).
    public func kill(root: ProcessID, in table: ProcessTable, gracePeriod: Duration = .seconds(3),
                     pollInterval: Duration = .milliseconds(50)) async -> [KillResult] {
        guard let rootSample = table.processes[root] else { return [] }
        if case .refused(let reason) = policy.verdict(for: rootSample, ownPID: ownPID) {
            return [KillResult(id: root, name: rootSample.name, outcome: .refused(reason: reason))]
        }

        let tree = ProcessTree(table: table)
        let order = (tree.descendants(of: root).reversed() + [root]).map { $0 }

        var results: [ProcessID: KillResult] = [:]
        var outputOrder: [ProcessID] = []
        var pending: [ProcessID] = []

        for id in order {
            guard let sample = table.processes[id] else { continue }
            outputOrder.append(id)
            if case .refused(let reason) = policy.verdict(for: sample, ownPID: ownPID) {
                results[id] = KillResult(id: id, name: sample.name, outcome: .refused(reason: reason))
                continue
            }
            // Guard against pid reuse since the table was sampled.
            guard let start = controller.startTime(pid: id.pid), start == id.startTime, controller.isAlive(pid: id.pid) else {
                results[id] = KillResult(id: id, name: sample.name, outcome: .alreadyGone)
                continue
            }
            let err = controller.send(SIGTERM, to: id.pid)
            if err == ESRCH {
                results[id] = KillResult(id: id, name: sample.name, outcome: .alreadyGone)
            } else if err != 0 {
                results[id] = KillResult(id: id, name: sample.name, outcome: .failed(errno: err))
            } else {
                pending.append(id)
            }
        }

        var survivors = await waitForExit(pending, timeout: gracePeriod, poll: pollInterval)
        for id in pending where !survivors.contains(id) {
            results[id] = KillResult(id: id, name: table.processes[id]?.name ?? "", outcome: .terminated)
        }

        if !survivors.isEmpty {
            // Children first again, so a supervising parent can't respawn them mid-escalation.
            for id in order where survivors.contains(id) { _ = controller.send(SIGKILL, to: id.pid) }
            survivors = await waitForExit(Array(survivors), timeout: .seconds(2), poll: pollInterval)
            for id in order where pending.contains(id) && results[id] == nil {
                let name = table.processes[id]?.name ?? ""
                results[id] = KillResult(id: id, name: name,
                                         outcome: survivors.contains(id) ? .failed(errno: EPERM) : .killed)
            }
        }

        return outputOrder.compactMap { results[$0] }
    }

    /// Polls until all `ids` are dead or `timeout` passes; returns the ones still alive.
    private func waitForExit(_ ids: [ProcessID], timeout: Duration, poll: Duration) async -> Set<ProcessID> {
        var alive = Set(ids.filter { controller.isAlive(pid: $0.pid) })
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while !alive.isEmpty, clock.now < deadline {
            try? await Task.sleep(for: poll)
            alive = alive.filter { controller.isAlive(pid: $0.pid) }
        }
        return alive
    }
}
