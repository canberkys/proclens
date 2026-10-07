import Darwin

/// IPv4/IPv6 address text from raw network-order bytes. Own implementation over `inet_ntop`.
public enum AddressFormatter {
    /// 4 bytes -> dotted quad, 16 bytes -> RFC 5952-style text (`inet_ntop`).
    /// A v4-mapped v6 address (`::ffff:a.b.c.d`) is rendered as its IPv4 form.
    public static func string(_ bytes: [UInt8]) -> String {
        switch bytes.count {
        case 4:
            return bytes.map(String.init).joined(separator: ".")
        case 16:
            if isV4Mapped(bytes) { return bytes[12...15].map(String.init).joined(separator: ".") }
            var buffer = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
            let ok = bytes.withUnsafeBytes { inet_ntop(AF_INET6, $0.baseAddress, &buffer, socklen_t(buffer.count)) }
            guard ok != nil else { return "?" }
            return String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        default:
            return ""
        }
    }

    public static func isV4Mapped(_ b: [UInt8]) -> Bool {
        b.count == 16 && b[0..<10].allSatisfy { $0 == 0 } && b[10] == 0xff && b[11] == 0xff
    }

    public static func isUnspecified(_ b: [UInt8]) -> Bool {
        (b.count == 4 || b.count == 16) && b.allSatisfy { $0 == 0 }
    }

    /// 127.0.0.0/8, ::1 and v4-mapped 127/8.
    public static func isLoopback(_ b: [UInt8]) -> Bool {
        switch b.count {
        case 4: return b[0] == 127
        case 16:
            if isV4Mapped(b) { return b[12] == 127 }
            return b[0..<15].allSatisfy { $0 == 0 } && b[15] == 1
        default: return false
        }
    }

    /// `host:port`, with brackets for IPv6 (`[::1]:8080`). Wildcard shows as `*`.
    public static func endpoint(address: [UInt8], port: UInt16) -> String {
        if address.isEmpty { return "*:\(port)" }
        let host = isUnspecified(address) ? "*" : string(address)
        return host.contains(":") ? "[\(host)]:\(port)" : "\(host):\(port)"
    }
}
