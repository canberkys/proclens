import Foundation

/// Evaluates rules against each snapshot and emits `AlertEvent`s. Pure logic: no notifications, no UI.
///
/// Semantics, per (rule, subject) where subject is a `ProcessID` or the system total:
/// - the value must be >= threshold continuously for `durationSeconds` (measured on snapshot instants);
///   dropping below, or the process disappearing, resets the timer;
/// - once fired, the episode is spent: no repeat until the value drops below and rises again;
/// - after a fire, new alerts for the same subject are suppressed for `cooldownSeconds`. A sustained
///   condition that is still true when the cooldown ends fires then;
/// - subjects are independent (two Chrome helpers over the limit are tracked separately);
/// - snapshots lacking the needed data (`processes`, `cpu`, `memory` nil) are skipped without resetting.
public actor AlertEngine {
    public nonisolated let events: AsyncStream<AlertEvent>
    private let continuation: AsyncStream<AlertEvent>.Continuation

    private enum Subject: Hashable { case system, process(ProcessID) }
    private struct Key: Hashable { let rule: UUID; let subject: Subject }
    private struct State {
        var exceededSince: ContinuousClock.Instant?
        var episodeFired = false
        var lastFired: ContinuousClock.Instant?
    }

    private var rules: [AlertRule]
    private var states: [Key: State] = [:]

    public init(rules: [AlertRule] = []) {
        self.rules = rules
        let (stream, continuation) = AsyncStream<AlertEvent>.makeStream(bufferingPolicy: .unbounded)
        self.events = stream
        self.continuation = continuation
    }

    deinit { continuation.finish() }

    public func setRules(_ newRules: [AlertRule]) {
        rules = newRules
        let ids = Set(newRules.map(\.id))
        states = states.filter { ids.contains($0.key.rule) }
    }

    public func currentRules() -> [AlertRule] { rules }

    /// Evaluates one snapshot; returns (and also yields on `events`) the alerts that fired.
    @discardableResult
    public func evaluate(_ snapshot: SystemSnapshot, wallClock: Date = Date()) -> [AlertEvent] {
        var fired: [AlertEvent] = []
        let now = snapshot.instant
        for rule in rules where rule.isEnabled {
            switch rule.target {
            case .systemTotal:
                guard let value = Self.systemValue(rule.metric, snapshot) else { continue }
                step(rule, .system, name: nil, value: value, now: now, wall: wallClock, into: &fired)
            case .anyProcess, .process:
                guard let table = snapshot.processes else { continue }
                var seen = Set<ProcessID>()
                for (id, p) in table.processes where rule.matches(processName: p.name) {
                    seen.insert(id)
                    step(rule, .process(id), name: p.name, value: Self.processValue(rule.metric, p), now: now,
                         wall: wallClock, into: &fired)
                }
                forgetProcesses(of: rule, notIn: seen, now: now)
            }
        }
        for e in fired { continuation.yield(e) }
        return fired
    }

    /// Forgets all timers and cooldowns.
    public func reset() { states.removeAll() }

    // MARK: -

    private func step(_ rule: AlertRule, _ subject: Subject, name: String?, value: Double,
                      now: ContinuousClock.Instant, wall: Date, into fired: inout [AlertEvent]) {
        let key = Key(rule: rule.id, subject: subject)
        var state = states[key] ?? State()
        defer { states[key] = (state.exceededSince == nil && state.lastFired == nil) ? nil : state }

        guard value >= rule.threshold else {
            state.exceededSince = nil
            state.episodeFired = false
            return
        }
        let since = state.exceededSince ?? now
        state.exceededSince = since
        guard !state.episodeFired else { return }
        let sustained = Self.seconds(now - since)
        guard sustained >= rule.durationSeconds else { return }
        if let last = state.lastFired, Self.seconds(now - last) < rule.cooldownSeconds { return }

        state.episodeFired = true
        state.lastFired = now
        var pid: ProcessID?
        if case .process(let id) = subject { pid = id }
        fired.append(AlertEvent(id: UUID(), ruleID: rule.id, ruleName: rule.name, processID: pid, processName: name,
                                metric: rule.metric, value: value, threshold: rule.threshold,
                                sustainedSeconds: sustained, firedAt: wall))
    }

    /// A process that left the table loses its timer; its cooldown stays (pid reuse is a new ProcessID anyway).
    private func forgetProcesses(of rule: AlertRule, notIn seen: Set<ProcessID>, now: ContinuousClock.Instant) {
        for key in states.keys where key.rule == rule.id {
            guard case .process(let id) = key.subject, !seen.contains(id) else { continue }
            if let last = states[key]?.lastFired, Self.seconds(now - last) < rule.cooldownSeconds {
                states[key]?.exceededSince = nil
                states[key]?.episodeFired = false
            } else {
                states[key] = nil
            }
        }
    }

    private static func seconds(_ d: Duration) -> Double {
        let c = d.components
        return Double(c.seconds) + Double(c.attoseconds) / 1e18
    }

    static func processValue(_ metric: AlertRule.Metric, _ p: ProcessSample) -> Double {
        switch metric {
        case .cpu: p.cpu * 100
        case .memory: Double(p.memory) / 1_048_576
        case .energy: p.energy
        }
    }

    static func systemValue(_ metric: AlertRule.Metric, _ s: SystemSnapshot) -> Double? {
        switch metric {
        case .cpu: s.cpu.map { $0.total * 100 }
        case .memory: s.memory.map { Double($0.used) / 1_048_576 }
        case .energy: s.processes.map { $0.processes.values.reduce(0) { $0 + $1.energy } }
        }
    }
}
