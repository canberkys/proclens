import Darwin
import Foundation
import Testing
@testable import ProcLensCore

@Suite struct LiveHostSourceTests {
    let source = LiveHostSource()

    @Test func cpuTicks() throws {
        let ticks = try source.cpuTicks()
        #expect(!ticks.isEmpty)
        #expect(ticks.count == ProcessInfo.processInfo.processorCount)
        #expect(ticks.contains { $0.idle > 0 })
    }

    @Test func perfLevelsMatchSysctl() throws {
        var n: Int32 = 0
        var len = MemoryLayout<Int32>.size
        let rc = sysctlbyname("hw.nperflevels", &n, &len, nil, 0)
        let levels = try source.perfLevels()
        #expect(levels.count == (rc == 0 ? Int(n) : 0))
        if !levels.isEmpty {
            #expect(levels.reduce(0) { $0 + $1.logicalCPUCount } == (try source.cpuTicks().count))
        }
    }

    @Test func vmStats() throws {
        let vm = try source.vmStats()
        #expect(vm.physicalMemory > 0)
        #expect(vm.wired > 0)
        #expect(vm.internal > 0)
    }

    @Test func pressureReadable() throws {
        _ = try source.memoryPressure()
    }

    @Test func collectorsEndToEnd() async throws {
        let cpu = CPUCollector(source: source)
        _ = try await cpu.sample(at: .now)
        let s = try await cpu.sample(at: .now)
        #expect(!s.cores.isEmpty)
        let mem = try await MemoryCollector(source: source).sample(at: .now)
        #expect(mem.total > 0)
        #expect(mem.used <= mem.total)
    }
}
