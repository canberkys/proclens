// Adapted from exelban/stats@ee4265f3, Modules/Net/readers.swift (getBytesInfo: sysctl NET_RT_IFLIST2 / if_msghdr2)
// Copyright (c) 2019 Serhiy Mytrovtsiy, MIT License (see THIRD_PARTY_NOTICES.md)

import Darwin

/// Per-interface 64-bit byte counters from the routing sysctl. Stateless.
public struct LiveNetworkSource: NetworkSource {
    public init() {}

    public func interfaces() throws -> [InterfaceCounters] {
        var mib: [Int32] = [CTL_NET, PF_ROUTE, 0, 0, NET_RT_IFLIST2, 0]
        var length = 0
        guard sysctl(&mib, UInt32(mib.count), nil, &length, nil, 0) == 0 else { throw SourceError("sysctl(NET_RT_IFLIST2)", errno: errno) }
        guard length > 0 else { return [] }
        // The table can grow between the size probe and the read; retry once with slack.
        var buffer = [UInt8](repeating: 0, count: length + length / 8)
        length = buffer.count
        guard sysctl(&mib, UInt32(mib.count), &buffer, &length, nil, 0) == 0 else { throw SourceError("sysctl(NET_RT_IFLIST2)", errno: errno) }

        var result: [InterfaceCounters] = []
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
                var nameBuffer = [CChar](repeating: 0, count: Int(IF_NAMESIZE))
                guard if_indextoname(UInt32(info.ifm_index), &nameBuffer) != nil else { continue }
                result.append(InterfaceCounters(
                    name: String(decoding: nameBuffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self),
                    bytesIn: info.ifm_data.ifi_ibytes,
                    bytesOut: info.ifm_data.ifi_obytes,
                    isLoopback: Int32(info.ifm_flags) & IFF_LOOPBACK != 0))
            }
        }
        return result
    }
}
