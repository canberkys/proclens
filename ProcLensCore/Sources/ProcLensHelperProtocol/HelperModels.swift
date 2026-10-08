import Foundation

/// Wire envelope: exactly one of `value` / `error` is set.
public struct HelperReply<Value: Codable & Sendable>: Codable, Sendable {
    public var value: Value?
    public var error: HelperFailure?

    public init(value: Value) { self.value = value; self.error = nil }
    public init(error: HelperFailure) { self.value = nil; self.error = error }

    public func unwrap() throws -> Value {
        if let error { throw error }
        guard let value else { throw HelperFailure(code: .internalError, message: "Empty reply") }
        return value
    }
}

public struct HelperEmpty: Codable, Sendable, Hashable { public init() {} }

public struct HelperFailure: Error, Codable, Sendable, Hashable, LocalizedError {
    public enum Code: String, Codable, Sendable {
        case badRequest, forbidden, notFound, processChanged, commandFailed, timedOut, versionMismatch, internalError
    }
    public var code: Code
    public var message: String
    public init(code: Code, message: String) { self.code = code; self.message = message }
    public var errorDescription: String? { message }
}

public struct HelperVersionInfo: Codable, Sendable, Hashable {
    public var protocolVersion: Int
    public var build: String
    public init(protocolVersion: Int, build: String) { self.protocolVersion = protocolVersion; self.build = build }
}

public struct HelperPIDRequest: Codable, Sendable, Hashable {
    public var pids: [Int32]
    public init(pids: [Int32]) { self.pids = pids }
}

/// `proc_pid_rusage` counters of one process, readable as root for processes the user cannot inspect.
/// Times are nanoseconds (mach absolute time already converted by the helper).
public struct HelperRusage: Codable, Sendable, Hashable {
    public var pid: Int32
    public var userTime: UInt64
    public var systemTime: UInt64
    public var physFootprint: UInt64
    public var diskBytesRead: UInt64
    public var diskBytesWritten: UInt64
    public var billedEnergy: UInt64
    public var interruptWakeups: UInt64
    public var packageIdleWakeups: UInt64
    public var startAbsTime: UInt64

    public init(pid: Int32, userTime: UInt64, systemTime: UInt64, physFootprint: UInt64, diskBytesRead: UInt64,
                diskBytesWritten: UInt64, billedEnergy: UInt64, interruptWakeups: UInt64,
                packageIdleWakeups: UInt64, startAbsTime: UInt64) {
        self.pid = pid; self.userTime = userTime; self.systemTime = systemTime
        self.physFootprint = physFootprint; self.diskBytesRead = diskBytesRead
        self.diskBytesWritten = diskBytesWritten; self.billedEnergy = billedEnergy
        self.interruptWakeups = interruptWakeups; self.packageIdleWakeups = packageIdleWakeups
        self.startAbsTime = startAbsTime
    }
}

public struct HelperProcessInfo: Codable, Sendable, Hashable {
    public var pid: Int32
    public var ppid: Int32
    public var uid: UInt32
    public var name: String
    public var path: String?
    /// Microseconds since the Unix epoch; same unit as `ProcessID.startTime`.
    public var startTime: UInt64
    public var threadCount: Int32

    public init(pid: Int32, ppid: Int32, uid: UInt32, name: String, path: String?, startTime: UInt64, threadCount: Int32) {
        self.pid = pid; self.ppid = ppid; self.uid = uid; self.name = name
        self.path = path; self.startTime = startTime; self.threadCount = threadCount
    }
}

public struct HelperListeningSocket: Codable, Sendable, Hashable {
    public enum TransportProtocol: String, Codable, Sendable { case tcp, udp }
    public var pid: Int32
    public var transport: TransportProtocol
    public var localAddress: String
    public var port: UInt16
    public var isIPv6: Bool

    public init(pid: Int32, transport: TransportProtocol, localAddress: String, port: UInt16, isIPv6: Bool) {
        self.pid = pid; self.transport = transport; self.localAddress = localAddress
        self.port = port; self.isIPv6 = isIPv6
    }
}

public struct HelperSignalRequest: Codable, Sendable, Hashable {
    public var pid: Int32
    public var signal: Int32
    /// `ProcessID.startTime` (µs since epoch) the caller saw. The helper refuses on mismatch (pid reuse).
    public var expectedStartTime: UInt64
    public init(pid: Int32, signal: Int32, expectedStartTime: UInt64) {
        self.pid = pid; self.signal = signal; self.expectedStartTime = expectedStartTime
    }
}

public struct HelperCommandOutput: Codable, Sendable, Hashable {
    public var exitStatus: Int32
    public var stdout: String
    public var stderr: String
    public init(exitStatus: Int32, stdout: String, stderr: String) {
        self.exitStatus = exitStatus; self.stdout = stdout; self.stderr = stderr
    }
}

/// JSON helpers shared by both ends of the connection.
public enum HelperCodec {
    public static func encode<T: Encodable>(_ value: T) -> Data {
        (try? JSONEncoder().encode(value)) ?? Data()
    }

    public static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        do { return try JSONDecoder().decode(type, from: data) } catch {
            throw HelperFailure(code: .badRequest, message: "Malformed message: \(error.localizedDescription)")
        }
    }

    public static func encodeReply<T: Codable & Sendable>(_ value: T) -> Data {
        encode(HelperReply(value: value))
    }

    public static func encodeFailure<T: Codable & Sendable>(_ error: any Error, as: T.Type) -> Data {
        let failure = (error as? HelperFailure) ?? HelperFailure(code: .internalError, message: error.localizedDescription)
        return encode(HelperReply<T>(error: failure))
    }
}
