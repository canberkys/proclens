import Foundation
@testable import ProcLensCore

/// Canned host source. Each `cpuTicks()` call pops the next reading (the last one repeats).
final class MockHostSource: HostSource, @unchecked Sendable {
    private let lock = NSLock()
    private var tickReadings: [[CoreTicks]]
    private var levels: [PerfLevel]
    private var vm: VMStats
    private var pressure: MemoryPressure

    init(ticks: [[CoreTicks]] = [], levels: [PerfLevel] = [], vm: VMStats = MockHostSource.emptyVM,
         pressure: MemoryPressure = .normal) {
        tickReadings = ticks
        self.levels = levels
        self.vm = vm
        self.pressure = pressure
    }

    static let emptyVM = VMStats(physicalMemory: 0, free: 0, active: 0, inactive: 0, speculative: 0,
                                 wired: 0, compressed: 0, purgeable: 0, external: 0, internal: 0, swapUsed: 0)

    func cpuTicks() throws -> [CoreTicks] {
        lock.lock(); defer { lock.unlock() }
        guard !tickReadings.isEmpty else { return [] }
        return tickReadings.count > 1 ? tickReadings.removeFirst() : tickReadings[0]
    }
    func perfLevels() throws -> [PerfLevel] { lock.lock(); defer { lock.unlock() }; return levels }
    func vmStats() throws -> VMStats { lock.lock(); defer { lock.unlock() }; return vm }
    func memoryPressure() throws -> MemoryPressure { lock.lock(); defer { lock.unlock() }; return pressure }
}
