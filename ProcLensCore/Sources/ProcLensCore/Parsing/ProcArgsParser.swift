import Foundation

/// Decoded `KERN_PROCARGS2` buffer.
public struct ProcArgs: Sendable, Hashable {
    public var executablePath: String
    public var arguments: [String]
    public var environment: [String: String]

    public init(executablePath: String, arguments: [String], environment: [String: String]) {
        self.executablePath = executablePath
        self.arguments = arguments
        self.environment = environment
    }
}

public enum ProcArgsParseError: Error, Sendable, Hashable {
    /// Fewer than 4 bytes: no argc.
    case tooShort
}

/// Pure parser for the `sysctl(KERN_PROCARGS2)` layout:
/// `Int32 argc` · exec path · NUL padding · `argc` NUL-terminated args · `K=V` env strings.
/// Tolerant of truncation, argc larger than the strings present, non-UTF-8 bytes
/// (lossy decode) and a missing environment.
public enum ProcArgsParser {
    public static func parse(_ bytes: [UInt8]) throws -> ProcArgs {
        guard bytes.count >= MemoryLayout<Int32>.size else { throw ProcArgsParseError.tooShort }
        var raw: Int32 = 0
        withUnsafeMutableBytes(of: &raw) { dst in
            for i in 0..<4 { dst[i] = bytes[i] }  // host byte order, same machine
        }
        let argc = max(0, Int(raw))
        var i = 4
        let n = bytes.count

        func readString() -> String? {
            guard i < n else { return nil }
            var end = i
            while end < n && bytes[end] != 0 { end += 1 }
            let s = String(decoding: bytes[i..<end], as: UTF8.self)
            i = min(end + 1, n)  // skip the NUL
            return s
        }

        let exec = readString() ?? ""
        while i < n && bytes[i] == 0 { i += 1 }  // padding

        var args: [String] = []
        args.reserveCapacity(min(argc, 64))
        while args.count < argc, let s = readString() { args.append(s) }

        var env: [String: String] = [:]
        // A fully read arg list is required before the environment makes sense.
        if args.count == argc {
            while i < n, bytes[i] != 0 {
                guard let entry = readString() else { break }
                if let eq = entry.firstIndex(of: "=") {
                    env[String(entry[..<eq])] = String(entry[entry.index(after: eq)...])
                } else if !entry.isEmpty {
                    env[entry] = ""
                }
            }
        }
        return ProcArgs(executablePath: exec, arguments: args, environment: env)
    }
}
