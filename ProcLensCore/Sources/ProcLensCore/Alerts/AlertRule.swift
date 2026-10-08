import Foundation

/// A threshold rule: "target's metric is at or above threshold for `durationSeconds`".
///
/// Units: `cpu` is percent (a process can exceed 100: 100 = one full core; the system total is 0...100),
/// `memory` is MiB (process footprint, or system used), `energy` is the approximate energy score from
/// `ProcessCollector` (system total = sum over processes). Name matching is case-insensitive.
public struct AlertRule: Codable, Identifiable, Sendable, Hashable {
    public enum NameMatch: String, Codable, Sendable { case exact, contains }

    public enum Target: Codable, Sendable, Hashable {
        case anyProcess
        case systemTotal
        case process(name: String, match: NameMatch)
    }

    public enum Metric: String, Codable, Sendable, CaseIterable { case cpu, memory, energy }

    public enum Comparison: String, Codable, Sendable { case atLeast }

    public var id: UUID
    public var name: String
    public var isEnabled: Bool
    public var target: Target
    public var metric: Metric
    public var comparison: Comparison
    public var threshold: Double
    /// The condition must hold continuously this long before the rule fires.
    public var durationSeconds: Double
    /// Minimum time between two alerts for the same (rule, process).
    public var cooldownSeconds: Double

    public init(id: UUID = UUID(), name: String, isEnabled: Bool = true, target: Target, metric: Metric,
                comparison: Comparison = .atLeast, threshold: Double, durationSeconds: Double,
                cooldownSeconds: Double = 300) {
        self.id = id
        self.name = name
        self.isEnabled = isEnabled
        self.target = target
        self.metric = metric
        self.comparison = comparison
        self.threshold = threshold
        self.durationSeconds = durationSeconds
        self.cooldownSeconds = cooldownSeconds
    }

    func matches(processName: String) -> Bool {
        switch target {
        case .anyProcess: return true
        case .systemTotal: return false
        case .process(let name, let match):
            switch match {
            case .exact: return processName.caseInsensitiveCompare(name) == .orderedSame
            case .contains: return processName.range(of: name, options: .caseInsensitive) != nil
            }
        }
    }
}

public struct AlertEvent: Sendable, Hashable, Identifiable {
    public let id: UUID
    public let ruleID: UUID
    public let ruleName: String
    /// nil for system-total rules.
    public let processID: ProcessID?
    public let processName: String?
    public let metric: AlertRule.Metric
    /// Value at the moment the rule fired, in the rule's units.
    public let value: Double
    public let threshold: Double
    public let sustainedSeconds: Double
    public let firedAt: Date

    public var message: String {
        let who = processName.map { "\($0) (\(processID?.pid ?? 0))" } ?? "System"
        let unit: String
        switch metric {
        case .cpu: unit = "% CPU"
        case .memory: unit = " MiB memory"
        case .energy: unit = " energy"
        }
        return "\(who): \(Int(value.rounded()))\(unit) for \(Int(sustainedSeconds.rounded())) s (limit \(Int(threshold.rounded())))"
    }
}
