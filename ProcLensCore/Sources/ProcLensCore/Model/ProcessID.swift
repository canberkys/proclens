import Darwin

/// Stable process identity. PIDs are reused, so a pid alone is not enough.
public struct ProcessID: Hashable, Sendable, Comparable, CustomStringConvertible {
    public let pid: pid_t
    /// Process start time in microseconds since the Unix epoch (`pbi_start_tvsec/usec`).
    public let startTime: UInt64

    public init(pid: pid_t, startTime: UInt64) {
        self.pid = pid
        self.startTime = startTime
    }

    public static func < (lhs: ProcessID, rhs: ProcessID) -> Bool {
        (lhs.pid, lhs.startTime) < (rhs.pid, rhs.startTime)
    }

    public var description: String { "\(pid)@\(startTime)" }
}
