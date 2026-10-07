import Foundation

/// System-wide metrics kept by `ProcessHistory`.
public enum HistoryMetric: String, Sendable, CaseIterable, Codable {
    /// 0...1, mean of all cores.
    case cpu
    /// Bytes in use (app + wired + compressed).
    case memory
    /// Bytes per second, read + write.
    case disk
    /// Bytes per second, received + sent over physical interfaces.
    case network
    /// 0...1, busiest GPU.
    case gpu
}

public enum HistoryProcessSort: Sendable, Hashable {
    case cpu, memory
}

/// One process in one 10 s bucket.
public struct HistoryProcessEntry: Sendable, Hashable, Identifiable {
    public let id: ProcessID
    public let name: String
    /// Mean over the ticks in the bucket where the process was present; 1.0 = one full core.
    public let cpu: Double
    /// Peak memory in the bucket, bytes.
    public let memory: UInt64

    public init(id: ProcessID, name: String, cpu: Double, memory: UInt64) {
        self.id = id
        self.name = name
        self.cpu = cpu
        self.memory = memory
    }
}

/// One point of a per-process series (one 10 s bucket in which the process was in a top list).
public struct HistoryProcessPoint: Sendable, Hashable {
    public let date: Date
    public let cpu: Double
    public let memory: UInt64
}

/// Five doubles indexed by `HistoryMetric`. NaN means "not collected".
struct MetricVector: Sendable {
    var cpu = Double.nan
    var memory = Double.nan
    var disk = Double.nan
    var network = Double.nan
    var gpu = Double.nan

    subscript(metric: HistoryMetric) -> Double {
        get {
            switch metric {
            case .cpu: cpu
            case .memory: memory
            case .disk: disk
            case .network: network
            case .gpu: gpu
            }
        }
        set {
            switch metric {
            case .cpu: cpu = newValue
            case .memory: memory = newValue
            case .disk: disk = newValue
            case .network: network = newValue
            case .gpu: gpu = newValue
            }
        }
    }
}

extension MetricVector {
    init(snapshot s: SystemSnapshot) {
        self.init()
        if let c = s.cpu { cpu = c.total }
        if let m = s.memory { memory = Double(m.used) }
        if let d = s.disk { disk = d.readPerSec + d.writePerSec }
        if let n = s.network { network = n.receivedPerSec + n.sentPerSec }
        if let g = s.gpu { gpu = g.utilization }
    }
}
