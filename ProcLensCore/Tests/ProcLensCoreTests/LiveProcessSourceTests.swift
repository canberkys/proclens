import Testing
import Darwin
import Foundation
@testable import ProcLensCore

struct LiveProcessSourceTests {
    let source = LiveProcessSource()
    let me = getpid()

    @Test func ownPidListedAndKernelOnce() throws {
        let pids = try source.allPIDs()
        #expect(pids.contains(me))
        #expect(pids.filter { $0 == 0 }.count <= 1)
        #expect(Set(pids).count == pids.count)
    }

    @Test func taskAllInfoOfSelf() throws {
        let info = try source.taskAllInfo(me)
        #expect(info.pid == me)
        #expect(info.ppid == getppid())
        #expect(info.uid == getuid())
        #expect(!info.name.isEmpty)
        #expect(info.startTime > 1_600_000_000_000_000)
        #expect(info.threadCount >= 1)
    }

    @Test func pathOfSelf() throws {
        let p = try source.path(me)
        #expect(p.hasPrefix("/"))
        #expect(FileManager.default.isExecutableFile(atPath: p))
        #expect(URL(fileURLWithPath: p).lastPathComponent == (try source.taskAllInfo(me)).name
                || !p.isEmpty)
    }

    @Test func rusageOfSelfInNanoseconds() throws {
        let a = try source.rusage(me)
        #expect(a.physFootprint > 0)
        var x = 0.0
        let start = ContinuousClock.now
        while ContinuousClock.now - start < .milliseconds(200) { x += 1 }
        let b = try source.rusage(me)
        let burned = b.userTime - a.userTime
        // ~200 ms of busy loop: if mach ticks were mistaken for ns this would be ~40x too small.
        #expect(burned > 100_000_000 && burned < 2_000_000_000, "burned \(burned) ns \(x)")
    }

    @Test func procArgsOfSelf() throws {
        let bytes = try source.procArgs(me)
        let parsed = try ProcArgsParser.parse(bytes)
        #expect(!parsed.arguments.isEmpty)
        #expect(parsed.arguments[0].hasSuffix((CommandLine.arguments[0] as NSString).lastPathComponent))
        #expect(parsed.executablePath.hasPrefix("/"))
    }

    @Test func missingPidThrowsESRCH() {
        #expect(throws: SourceError.self) { try source.taskAllInfo(999_999) }
        do { _ = try source.rusage(999_999) } catch let e as SourceError { #expect(e.isGone) } catch {}
    }

    @Test func fullSamplePerformance() async throws {
        let c = ProcessCollector(source: source)
        let t0 = ContinuousClock.now
        _ = try await c.sample(at: t0)  // warm: fills path cache
        let start = ContinuousClock.now
        let table = try await c.sample(at: t0.advanced(by: .seconds(1)))
        let elapsed = ContinuousClock.now - start
        let restricted = table.processes.values.filter(\.isRestricted).count
        print("PERF processes=\(table.processes.count) restricted=\(restricted) elapsed=\(elapsed)")
        #expect(table.processes.count > 50)
        #expect(elapsed < .milliseconds(50))
    }
}
