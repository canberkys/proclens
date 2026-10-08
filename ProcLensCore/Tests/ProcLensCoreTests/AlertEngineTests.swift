import Foundation
import Testing
@testable import ProcLensCore

@Suite struct AlertEngineTests {
    let base = ContinuousClock.now

    func snap(_ s: Double, _ procs: [ProcessSample]) -> SystemSnapshot {
        Synth.snapshot(at: s, base: base, processes: Synth.table(procs))
    }

    func rule(target: AlertRule.Target = .process(name: "node", match: .exact), threshold: Double = 80,
              duration: Double = 60, cooldown: Double = 300, metric: AlertRule.Metric = .cpu) -> AlertRule {
        AlertRule(name: "r", target: target, metric: metric, threshold: threshold, durationSeconds: duration,
                  cooldownSeconds: cooldown)
    }

    /// Runs one snapshot per second for `seconds`, returns fire times.
    func run(_ engine: AlertEngine, from: Int, to: Int, _ procs: @Sendable (Int) -> [ProcessSample]) async -> [Int] {
        var fires: [Int] = []
        for s in from..<to where !(await engine.evaluate(snap(Double(s), procs(s)))).isEmpty { fires.append(s) }
        return fires
    }

    @Test func sustainedSixtySecondsAtEightyPercentFiresOnce() async {
        let engine = AlertEngine(rules: [rule()])
        let fires = await run(engine, from: 0, to: 200) { _ in [Synth.process(1, cpu: 0.9, memory: 0, name: "node")] }
        #expect(fires == [60])
    }

    @Test func belowThresholdNeverFiresAndDroppingResetsTheTimer() async {
        let engine = AlertEngine(rules: [rule(cooldown: 0)])
        // 50 s hot, 1 s cool, 50 s hot: never 60 s continuous.
        let fires = await run(engine, from: 0, to: 101) { s in
            [Synth.process(1, cpu: s == 50 ? 0.2 : 0.9, memory: 0, name: "node")]
        }
        #expect(fires.isEmpty)
        // 59 s of hot is not enough either; 60 s is.
        let e2 = AlertEngine(rules: [rule()])
        #expect(await run(e2, from: 0, to: 60) { _ in [Synth.process(1, cpu: 0.8, memory: 0, name: "node")] }.isEmpty)
        #expect(await run(e2, from: 60, to: 62) { _ in [Synth.process(1, cpu: 0.8, memory: 0, name: "node")] } == [60])
    }

    @Test func cooldownSuppressesRepeatAlerts() async {
        let engine = AlertEngine(rules: [rule(duration: 10, cooldown: 100)])
        // Hot 0-30 (fires at 10), cool 31-40, hot again 41-... (would re-fire at 51, inside cooldown until 110).
        let fires = await run(engine, from: 0, to: 250) { s in
            [Synth.process(1, cpu: (31..<41).contains(s) ? 0.1 : 0.95, memory: 0, name: "node")]
        }
        // First fire at 10; the second episode began at 41, is suppressed, and fires when the cooldown ends (110).
        #expect(fires == [10, 110])
    }

    @Test func eventsCarryTheDetails() async {
        let engine = AlertEngine(rules: [rule(duration: 2)])
        var out: [AlertEvent] = []
        for s in 0..<4 { out += await engine.evaluate(snap(Double(s), [Synth.process(7, cpu: 1.5, memory: 0, name: "node")])) }
        #expect(out.count == 1)
        #expect(out[0].processID?.pid == 7)
        #expect(out[0].processName == "node")
        #expect(out[0].value == 150)
        #expect(out[0].sustainedSeconds >= 2)
        #expect(out[0].message.contains("node"))
    }

    @Test func processesAreTrackedIndependently() async {
        let engine = AlertEngine(rules: [rule(target: .anyProcess, duration: 10)])
        var firedPids: [Int32: Int] = [:]
        for s in 0..<40 {
            let procs = [
                Synth.process(1, cpu: 0.9, memory: 0, name: "a"),                                  // hot from 0
                Synth.process(2, cpu: s < 20 ? 0.1 : 0.9, memory: 0, name: "b"),                   // hot from 20
                Synth.process(3, cpu: 0.2, memory: 0, name: "c"),                                  // never
            ]
            for e in await engine.evaluate(snap(Double(s), procs)) { firedPids[e.processID!.pid] = s }
        }
        #expect(firedPids == [1: 10, 2: 30])
    }

    @Test func nameMatchingExactAndContains() async {
        let exact = rule(target: .process(name: "node", match: .exact), duration: 0)
        let contains = rule(target: .process(name: "chrome", match: .contains), duration: 0)
        let procs = [Synth.process(1, cpu: 1, memory: 0, name: "node"), Synth.process(2, cpu: 1, memory: 0, name: "nodemon"),
                     Synth.process(3, cpu: 1, memory: 0, name: "Google Chrome Helper")]
        let e1 = await AlertEngine(rules: [exact]).evaluate(snap(0, procs))
        #expect(e1.map(\.processID?.pid) == [1])
        let e2 = await AlertEngine(rules: [contains]).evaluate(snap(0, procs))
        #expect(e2.map(\.processID?.pid) == [3])
    }

    @Test func systemTotalAndMemoryUnits() async {
        let engine = AlertEngine(rules: [
            rule(target: .systemTotal, threshold: 90, duration: 3),
            rule(target: .anyProcess, threshold: 1024, duration: 0, metric: .memory),
        ])
        var events: [AlertEvent] = []
        for s in 0..<5 {
            events += await engine.evaluate(Synth.snapshot(at: Double(s), base: base, cpu: 0.95,
                                                           processes: Synth.table([Synth.process(1, cpu: 0, memory: 2 << 30)])))
        }
        #expect(events.count == 2)
        #expect(events.contains { $0.processID == nil && $0.metric == .cpu })
        #expect(events.contains { $0.processID?.pid == 1 && $0.metric == .memory && $0.value == 2048 })
    }

    @Test func vanishedProcessResetsAndDisabledRulesAreSkipped() async {
        var r = rule(duration: 10, cooldown: 0)
        let engine = AlertEngine(rules: [r])
        let hot = Synth.process(1, cpu: 0.9, memory: 0, name: "node")
        for s in 0..<8 { await engine.evaluate(snap(Double(s), [hot])) }
        await engine.evaluate(snap(8, []))              // gone: timer reset
        #expect(await run(engine, from: 9, to: 18) { _ in [hot] }.isEmpty)
        r.isEnabled = false
        await engine.setRules([r])
        #expect(await run(engine, from: 20, to: 60) { _ in [hot] }.isEmpty)
    }

    @Test func snapshotsWithoutProcessDataDoNotResetTimers() async {
        let engine = AlertEngine(rules: [rule(duration: 5)])
        let hot = Synth.process(1, cpu: 0.9, memory: 0, name: "node")
        await engine.evaluate(snap(0, [hot]))
        await engine.evaluate(Synth.snapshot(at: 2, base: base, processes: nil))
        #expect(!(await engine.evaluate(snap(5, [hot]))).isEmpty)
    }

    @Test func eventsStreamDelivers() async {
        let engine = AlertEngine(rules: [rule(duration: 0)])
        await engine.evaluate(snap(0, [Synth.process(1, cpu: 1, memory: 0, name: "node")]))
        var it = engine.events.makeAsyncIterator()
        let e = await it.next()
        #expect(e?.processName == "node")
    }
}

@Suite struct AlertRuleStoreTests {
    @Test func roundTripAndMissingFile() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("proclens-alerts-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = AlertRuleStore(url: dir.appendingPathComponent("sub/rules.json"))
        #expect(try store.load().isEmpty)
        let rules = [
            AlertRule(name: "Node hog", target: .process(name: "node", match: .contains), metric: .cpu, threshold: 80, durationSeconds: 60),
            AlertRule(name: "Mem", isEnabled: false, target: .anyProcess, metric: .memory, threshold: 4096, durationSeconds: 30, cooldownSeconds: 900),
            AlertRule(name: "Sys", target: .systemTotal, metric: .cpu, threshold: 95, durationSeconds: 120),
        ]
        try store.save(rules)
        #expect(try store.load() == rules)
    }

    @Test func corruptFileThrows() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("proclens-bad-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data("nope".utf8).write(to: url)
        #expect(throws: (any Error).self) { try AlertRuleStore(url: url).load() }
    }
}
