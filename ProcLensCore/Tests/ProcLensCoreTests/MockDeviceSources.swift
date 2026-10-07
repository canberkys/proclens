import Foundation
@testable import ProcLensCore

/// Canned IORegistry source. Each call pops the next reading (the last one repeats).
final class MockIORegistrySource: IORegistrySource, @unchecked Sendable {
    private let lock = NSLock()
    private var gpuReadings: [[GPUDeviceSample]]
    private var blockReadings: [[BlockDeviceCounters]]

    init(gpu: [[GPUDeviceSample]] = [], blocks: [[BlockDeviceCounters]] = []) {
        gpuReadings = gpu
        blockReadings = blocks
    }

    private static func next<T>(_ readings: inout [[T]]) -> [T] {
        guard !readings.isEmpty else { return [] }
        return readings.count > 1 ? readings.removeFirst() : readings[0]
    }

    func gpuDevices() throws -> [GPUDeviceSample] { lock.lock(); defer { lock.unlock() }; return Self.next(&gpuReadings) }
    func blockDevices() throws -> [BlockDeviceCounters] { lock.lock(); defer { lock.unlock() }; return Self.next(&blockReadings) }
}

final class MockNetworkSource: NetworkSource, @unchecked Sendable {
    private let lock = NSLock()
    private var readings: [[InterfaceCounters]]

    init(_ readings: [[InterfaceCounters]]) { self.readings = readings }

    func interfaces() throws -> [InterfaceCounters] {
        lock.lock(); defer { lock.unlock() }
        guard !readings.isEmpty else { return [] }
        return readings.count > 1 ? readings.removeFirst() : readings[0]
    }
}
