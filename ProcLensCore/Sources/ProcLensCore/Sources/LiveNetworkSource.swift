// Adapted from exelban/stats@ee4265f3, Modules/Net/readers.swift (getBytesInfo: sysctl NET_RT_IFLIST2 / if_msghdr2)
// Copyright (c) 2019 Serhiy Mytrovtsiy, MIT License (see THIRD_PARTY_NOTICES.md)

import Darwin
import Foundation

/// Per-interface 64-bit byte counters from the routing sysctl. Stateless.
public final class LiveNetworkSource: NetworkSource, @unchecked Sendable {
    // Caches guarded by `lock`: the routing buffer (reused across ticks) and index -> name
    // (if_indextoname is a syscall per interface; indexes are not reused while an interface lives).
    private let lock = NSLock()
    private var buffer: [UInt8] = []
    private var names: [UInt32: String] = [:]

    public init() {}

    public func interfaces() throws -> [InterfaceCounters] {
        lock.lock()
        defer { lock.unlock() }
        var mib: [Int32] = [CTL_NET, PF_ROUTE, 0, 0, NET_RT_IFLIST2, 0]
        var length = buffer.count
        var attempts = 0
        while true {
            if buffer.isEmpty {
                var probe = 0
                guard sysctl(&mib, UInt32(mib.count), nil, &probe, nil, 0) == 0 else {
                    throw SourceError("sysctl(NET_RT_IFLIST2)", errno: errno)
                }
                guard probe > 0 else { return [] }
                buffer = [UInt8](repeating: 0, count: probe + probe / 4)  // slack: the table can grow
            }
            length = buffer.count
            if sysctl(&mib, UInt32(mib.count), &buffer, &length, nil, 0) == 0 { break }
            let e = errno
            attempts += 1
            guard e == ENOMEM, attempts < 3 else { throw SourceError("sysctl(NET_RT_IFLIST2)", errno: e) }
            buffer = []  // too small: re-probe
        }

        var result: [InterfaceCounters] = []
        result.reserveCapacity(names.count)
        buffer.withUnsafeBytes { raw in
            var offset = 0
            while offset + MemoryLayout<if_msghdr>.size <= length {
                // Records are not guaranteed to be aligned for the struct, so read unaligned.
                let header = raw.loadUnaligned(fromByteOffset: offset, as: if_msghdr.self)
                let size = Int(header.ifm_msglen)
                guard size > 0, offset + size <= length else { break }
                defer { offset += size }
                guard Int32(header.ifm_type) == RTM_IFINFO2,
                      size >= MemoryLayout<if_msghdr2>.size else { continue }
                let info = raw.loadUnaligned(fromByteOffset: offset, as: if_msghdr2.self)
                let index = UInt32(info.ifm_index)
                var name = names[index]
                if name == nil {
                    var nameBuffer = [CChar](repeating: 0, count: Int(IF_NAMESIZE))
                    guard if_indextoname(index, &nameBuffer) != nil else { continue }
                    name = String(decoding: nameBuffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
                    names[index] = name
                }
                result.append(InterfaceCounters(
                    name: name ?? "",
                    bytesIn: info.ifm_data.ifi_ibytes,
                    bytesOut: info.ifm_data.ifi_obytes,
                    isLoopback: Int32(info.ifm_flags) & IFF_LOOPBACK != 0))
            }
        }
        return result
    }
}
