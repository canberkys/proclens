import Foundation
import Darwin
@testable import ProcLensCore

enum Synth {
    static func process(_ i: Int, cpu: Double, memory: UInt64, name: String? = nil) -> ProcessSample {
        ProcessSample(id: ProcessID(pid: pid_t(i), startTime: UInt64(1_000 + i)), ppid: 1, uid: 501,
                      name: name ?? "proc\(i)", path: nil, threadCount: 4, isTranslated: false, cpu: cpu, memory: memory,
                      diskReadPerSec: 0, diskWritePerSec: 0, energy: cpu * 100, isRestricted: false)
    }

    static func table(_ procs: [ProcessSample]) -> ProcessTable {
        ProcessTable(processes: Dictionary(uniqueKeysWithValues: procs.map { ($0.id, $0) }))
    }

    static func cpuSample(total: Double) -> CPUSample {
        CPUSample(cores: [CPUCoreSample(index: 0, kind: .performance, user: total, system: 0)])
    }

    static func snapshot(at offset: Double = 0, base: ContinuousClock.Instant = .now, cpu: Double? = 0.1,
                         memoryUsed: UInt64? = 8 << 30, processes: ProcessTable? = nil, disk: Double? = nil,
                         network: Double? = nil, gpu: Double? = nil) -> SystemSnapshot {
        SystemSnapshot(
            tick: 0, instant: base.advanced(by: .milliseconds(Int(offset * 1000))),
            cpu: cpu.map(cpuSample(total:)),
            memory: memoryUsed.map { MemorySample(total: 16 << 30, app: $0, wired: 0, compressed: 0, cached: 0, swapUsed: 0, pressure: .normal) },
            processes: processes,
            gpu: gpu.map { GPUSample(devices: [GPUDeviceSample(name: "G", utilization: $0)]) },
            disk: disk.map { DiskSample(readPerSec: $0, writePerSec: 0) },
            network: network.map { NetworkSample(interfaces: [NetworkInterfaceSample(name: "en0", receivedPerSec: $0, sentPerSec: 0)]) })
    }
}
