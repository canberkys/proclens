// Adapted from exelban/stats@ee4265f3, Modules/CPU/readers.swift (LoadReader.read) and Modules/RAM/readers.swift (UsageReader.read)
// Copyright (c) 2019 Serhiy Mytrovtsiy, MIT License (see THIRD_PARTY_NOTICES.md)

import Darwin

/// Real Mach host + sysctl reads. Stateless apart from the cached host port, so it is trivially `Sendable`.
public struct LiveHostSource: HostSource {
    /// `mach_host_self()` returns a new send right on every call; fetch it once per process.
    private static let hostPort: mach_port_t = mach_host_self()

    public init() {}

    // MARK: CPU

    public func cpuTicks() throws -> [CoreTicks] {
        var cpuCount: natural_t = 0
        var info: processor_info_array_t?
        var infoCount: mach_msg_type_number_t = 0
        let kr = host_processor_info(Self.hostPort, PROCESSOR_CPU_LOAD_INFO, &cpuCount, &info, &infoCount)
        guard kr == KERN_SUCCESS, let info else { throw SourceError("host_processor_info", errno: kr) }
        defer {
            let size = vm_size_t(MemoryLayout<integer_t>.stride * Int(infoCount))
            vm_deallocate(mach_task_self_, vm_address_t(bitPattern: info), size)
        }
        let stride = Int(CPU_STATE_MAX)
        return (0..<Int(cpuCount)).map { i in
            func tick(_ state: Int32) -> UInt64 { UInt64(UInt32(bitPattern: info[i * stride + Int(state)])) }
            return CoreTicks(user: tick(CPU_STATE_USER), system: tick(CPU_STATE_SYSTEM),
                             idle: tick(CPU_STATE_IDLE), nice: tick(CPU_STATE_NICE))
        }
    }

    // MARK: Perf levels

    public func perfLevels() throws -> [PerfLevel] {
        // Intel Macs have no hw.nperflevels.
        guard let count = Self.sysctlInt32("hw.nperflevels"), count > 0 else { return [] }
        var levels: [PerfLevel] = []
        for n in 0..<Int(count) {
            guard let cpus = Self.sysctlInt32("hw.perflevel\(n).logicalcpu") else { continue }
            let name = Self.sysctlString("hw.perflevel\(n).name") ?? ""
            levels.append(PerfLevel(level: n, name: name, logicalCPUCount: Int(cpus)))
        }
        return levels
    }

    // MARK: Memory

    public func vmStats() throws -> VMStats {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
        let kr = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(Self.hostPort, HOST_VM_INFO64, $0, &count)
            }
        }
        guard kr == KERN_SUCCESS else { throw SourceError("host_statistics64", errno: kr) }

        // Pages are the kernel page size (16 KiB on Apple Silicon), not a hard-coded 4096.
        // host_page_size reports the same value as vm_kernel_page_size without touching a mutable C global.
        var pageSize: vm_size_t = 0
        host_page_size(Self.hostPort, &pageSize)
        let page = UInt64(pageSize > 0 ? pageSize : 16_384)

        var memsize: UInt64 = 0
        var memsizeLen = MemoryLayout<UInt64>.size
        guard sysctlbyname("hw.memsize", &memsize, &memsizeLen, nil, 0) == 0 else {
            throw SourceError("sysctl hw.memsize", errno: errno)
        }

        var swap = xsw_usage()
        var swapLen = MemoryLayout<xsw_usage>.size
        let swapUsed: UInt64 = sysctlbyname("vm.swapusage", &swap, &swapLen, nil, 0) == 0 ? swap.xsu_used : 0

        func bytes(_ pages: some BinaryInteger) -> UInt64 { UInt64(pages) * page }
        return VMStats(
            physicalMemory: memsize,
            free: bytes(stats.free_count),
            active: bytes(stats.active_count),
            inactive: bytes(stats.inactive_count),
            speculative: bytes(stats.speculative_count),
            wired: bytes(stats.wire_count),
            compressed: bytes(stats.compressor_page_count),
            purgeable: bytes(stats.purgeable_count),
            external: bytes(stats.external_page_count),
            internal: bytes(stats.internal_page_count),
            swapUsed: swapUsed
        )
    }

    public func memoryPressure() throws -> MemoryPressure {
        var level: Int32 = 0
        var len = MemoryLayout<Int32>.size
        guard sysctlbyname("kern.memorystatus_vm_pressure_level", &level, &len, nil, 0) == 0 else {
            throw SourceError("sysctl kern.memorystatus_vm_pressure_level", errno: errno)
        }
        switch level {
        case 2: return .warning
        case 4: return .critical
        default: return .normal
        }
    }

    // MARK: sysctl helpers

    private static func sysctlInt32(_ name: String) -> Int32? {
        var value: Int32 = 0
        var len = MemoryLayout<Int32>.size
        return sysctlbyname(name, &value, &len, nil, 0) == 0 ? value : nil
    }

    private static func sysctlString(_ name: String) -> String? {
        var len = 0
        guard sysctlbyname(name, nil, &len, nil, 0) == 0, len > 0 else { return nil }
        var buf = [CChar](repeating: 0, count: len)
        guard sysctlbyname(name, &buf, &len, nil, 0) == 0 else { return nil }
        return String(decoding: buf.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }
}
