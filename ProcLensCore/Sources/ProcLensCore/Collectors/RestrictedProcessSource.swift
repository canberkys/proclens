import Foundation
import ProcLensHelperProtocol

/// Supplies the per-process counters of processes this app cannot read itself (EPERM as non-root).
/// Implemented by `HelperClient` (privileged helper over XPC); mocked in tests.
public protocol RestrictedProcessSource: Sendable {
    /// Cheap, non-blocking: true when the source can currently serve requests (helper registered and approved).
    var isEnabled: Bool { get }
    /// `proc_pid_rusage` of every pid that still exists, in one round trip.
    func readRusage(pids: [Int32]) async throws -> [HelperRusage]
    /// Thread count / path of every pid that still exists, in one round trip.
    func readProcessInfo(pids: [Int32]) async throws -> [HelperProcessInfo]
}

/// Signals a process the app is not allowed to signal itself (the helper refuses critical processes).
public protocol PrivilegedSignaller: Sendable {
    var isEnabled: Bool { get }
    /// `expectedStartTime` is `ProcessID.startTime` (µs); 0 means "unknown" (the app cannot read the start time of
    /// root-owned processes), in which case the implementation resolves it and checks `expectedName` instead.
    func signalProcess(pid: Int32, signal: Int32, expectedStartTime: UInt64, expectedName: String?) async throws
}
