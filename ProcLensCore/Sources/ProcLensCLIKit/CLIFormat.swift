import Foundation
import ProcLensCore

// MARK: - Rows

/// A record that can be shown as a table, CSV or stable JSON.
public protocol CLIRow: Codable, Sendable {
    static var headers: [String] { get }
    /// Columns (by index) that are right-aligned in table output.
    static var rightAligned: Set<Int> { get }
    var tableCells: [String] { get }
    var csvCells: [String] { get }
}

func round1(_ v: Double) -> Double { (v * 10).rounded() / 10 }
func round2(_ v: Double) -> Double { (v * 100).rounded() / 100 }

public struct ProcessRow: CLIRow, Equatable {
    public var pid: Int32
    public var name: String
    public var user: String
    public var cpuPercent: Double
    public var memoryBytes: UInt64
    public var threads: Int32
    public var arch: String
    public var translated: Bool

    public init(pid: Int32, name: String, user: String, cpuPercent: Double, memoryBytes: UInt64, threads: Int32,
                arch: String, translated: Bool) {
        self.pid = pid
        self.name = name
        self.user = user
        self.cpuPercent = round1(cpuPercent)
        self.memoryBytes = memoryBytes
        self.threads = threads
        self.arch = arch
        self.translated = translated
    }

    public init(_ p: ProcessSample, user: String) {
        #if arch(arm64)
        let native = "arm64"
        #else
        let native = "x86_64"
        #endif
        self.init(pid: p.pid, name: p.name, user: user, cpuPercent: p.cpu * 100, memoryBytes: p.memory,
                  threads: p.threadCount, arch: p.isTranslated ? "x86_64" : native, translated: p.isTranslated)
    }

    public static let headers = ["PID", "NAME", "USER", "CPU%", "MEM", "THREADS", "ARCH"]
    public static let rightAligned: Set<Int> = [0, 3, 4, 5]
    public var tableCells: [String] {
        [String(pid), name, user, String(format: "%.1f", cpuPercent), Bytes.format(memoryBytes), String(threads),
         translated ? "x86_64 (Rosetta)" : arch]
    }
    public var csvCells: [String] {
        [String(pid), name, user, String(format: "%.1f", cpuPercent), String(memoryBytes), String(threads), arch]
    }
}

public struct PortRow: CLIRow, Equatable {
    public var port: Int
    public var proto: String
    public var address: String
    public var loopbackOnly: Bool
    public var pid: Int32
    public var process: String
    public var framework: String
    public var category: String

    public init(port: Int, proto: String, address: String, loopbackOnly: Bool, pid: Int32, process: String,
                framework: String, category: String) {
        self.port = port
        self.proto = proto
        self.address = address
        self.loopbackOnly = loopbackOnly
        self.pid = pid
        self.process = process
        self.framework = framework
        self.category = category
    }

    public static let headers = ["PORT", "PROTO", "ADDRESS", "PID", "PROCESS", "KIND"]
    public static let rightAligned: Set<Int> = [0, 3]
    public var tableCells: [String] {
        [String(port), proto, address, String(pid), process, framework]
    }
    public var csvCells: [String] {
        [String(port), proto, address, String(pid), process, framework]
    }
}

public struct LaunchdRow: CLIRow, Equatable {
    public var label: String
    public var scope: String
    public var domain: String
    public var enabled: Bool
    public var loaded: Bool
    public var running: Bool
    public var pid: Int?
    public var lastExitStatus: Int?
    public var program: String

    public init(label: String, scope: String, domain: String, enabled: Bool, loaded: Bool, running: Bool, pid: Int?,
                lastExitStatus: Int?, program: String) {
        self.label = label
        self.scope = scope
        self.domain = domain
        self.enabled = enabled
        self.loaded = loaded
        self.running = running
        self.pid = pid
        self.lastExitStatus = lastExitStatus
        self.program = program
    }

    public init(_ s: LaunchdItemStatus) {
        self.init(label: s.item.label, scope: s.item.scope.rawValue, domain: s.item.domain.specifier,
                  enabled: s.isEnabled, loaded: s.isLoaded, running: s.isRunning, pid: s.pid,
                  lastExitStatus: s.lastExitStatus, program: s.item.program)
    }

    public static let headers = ["LABEL", "SCOPE", "ENABLED", "STATE", "PID", "EXIT", "PROGRAM"]
    public static let rightAligned: Set<Int> = [4, 5]
    private var state: String { running ? "running" : loaded ? "loaded" : "not loaded" }
    public var tableCells: [String] {
        [label, scope, enabled ? "yes" : "no", state, pid.map(String.init) ?? "-", lastExitStatus.map(String.init) ?? "-", program]
    }
    public var csvCells: [String] {
        [label, scope, enabled ? "true" : "false", state, pid.map(String.init) ?? "", lastExitStatus.map(String.init) ?? "", program]
    }
}

// MARK: - System report

public struct SystemReport: Codable, Sendable, Equatable {
    public struct Core: Codable, Sendable, Equatable {
        public var index: Int
        public var kind: String
        public var percent: Double
    }
    public struct CPU: Codable, Sendable, Equatable {
        public var totalPercent: Double
        public var cores: [Core]
    }
    public struct Memory: Codable, Sendable, Equatable {
        public var totalBytes: UInt64
        public var usedBytes: UInt64
        public var appBytes: UInt64
        public var wiredBytes: UInt64
        public var compressedBytes: UInt64
        public var cachedBytes: UInt64
        public var swapUsedBytes: UInt64
        public var pressure: String
    }
    public struct GPUDevice: Codable, Sendable, Equatable {
        public var name: String
        public var percent: Double
    }
    public struct GPU: Codable, Sendable, Equatable {
        public var utilizationPercent: Double
        public var devices: [GPUDevice]
    }
    public struct Disk: Codable, Sendable, Equatable {
        public var readBytesPerSec: Double
        public var writeBytesPerSec: Double
    }
    public struct Interface: Codable, Sendable, Equatable {
        public var name: String
        public var receivedBytesPerSec: Double
        public var sentBytesPerSec: Double
    }
    public struct Network: Codable, Sendable, Equatable {
        public var receivedBytesPerSec: Double
        public var sentBytesPerSec: Double
        public var interfaces: [Interface]
    }

    public var processCount: Int?
    public var cpu: CPU?
    public var memory: Memory?
    public var gpu: GPU?
    public var disk: Disk?
    public var network: Network?

    public init(_ s: SystemSnapshot) {
        processCount = s.processes?.processes.count
        cpu = s.cpu.map { c in
            CPU(totalPercent: round1(c.total * 100),
                cores: c.cores.map { Core(index: $0.index, kind: $0.kind.rawValue, percent: round1($0.total * 100)) })
        }
        memory = s.memory.map {
            Memory(totalBytes: $0.total, usedBytes: $0.used, appBytes: $0.app, wiredBytes: $0.wired,
                   compressedBytes: $0.compressed, cachedBytes: $0.cached, swapUsedBytes: $0.swapUsed,
                   pressure: $0.pressure.rawValue)
        }
        gpu = s.gpu.map { g in
            GPU(utilizationPercent: round1(g.utilization * 100),
                devices: g.devices.map { GPUDevice(name: $0.name, percent: round1($0.utilization * 100)) })
        }
        disk = s.disk.map { Disk(readBytesPerSec: round2($0.readPerSec), writeBytesPerSec: round2($0.writePerSec)) }
        network = s.network.map { n in
            Network(receivedBytesPerSec: round2(n.receivedPerSec), sentBytesPerSec: round2(n.sentPerSec),
                    interfaces: n.interfaces.map {
                        Interface(name: $0.name, receivedBytesPerSec: round2($0.receivedPerSec),
                                  sentBytesPerSec: round2($0.sentPerSec))
                    })
        }
    }

    /// Human-readable multi-line summary.
    public func text() -> String {
        var lines: [String] = []
        if let c = cpu {
            let p = c.cores.filter { $0.kind == "performance" }.count, e = c.cores.filter { $0.kind == "efficiency" }.count
            lines.append("CPU      \(String(format: "%.1f", c.totalPercent))%  (\(c.cores.count) cores" + (p + e > 0 ? ": \(p)P + \(e)E)" : ")"))
        }
        if let m = memory {
            lines.append("Memory   \(Bytes.format(m.usedBytes)) of \(Bytes.format(m.totalBytes)) used  pressure \(m.pressure)"
                         + "  (app \(Bytes.format(m.appBytes)), wired \(Bytes.format(m.wiredBytes)), compressed \(Bytes.format(m.compressedBytes)), swap \(Bytes.format(m.swapUsedBytes)))")
        }
        if let g = gpu { lines.append("GPU      \(String(format: "%.1f", g.utilizationPercent))%" + (g.devices.first.map { "  (\($0.name))" } ?? "")) }
        if let d = disk { lines.append("Disk     read \(Bytes.format(UInt64(d.readBytesPerSec)))/s  write \(Bytes.format(UInt64(d.writeBytesPerSec)))/s") }
        if let n = network { lines.append("Network  down \(Bytes.format(UInt64(n.receivedBytesPerSec)))/s  up \(Bytes.format(UInt64(n.sentBytesPerSec)))/s") }
        if let n = processCount { lines.append("Processes \(n)") }
        return lines.joined(separator: "\n")
    }
}

public struct TopFrame: Codable, Sendable, Equatable {
    public var time: String
    public var system: SystemReport
    public var processes: [ProcessRow]
}

// MARK: - Rendering

public enum Bytes {
    /// Binary units with one decimal for GB and above, e.g. `1.5 GB`, `340 MB`, `12 KB`.
    public static func format(_ bytes: UInt64) -> String {
        let units = ["B", "KB", "MB", "GB", "TB"]
        var v = Double(bytes), i = 0
        while v >= 1024, i < units.count - 1 { v /= 1024; i += 1 }
        return i >= 3 ? String(format: "%.1f %@", v, units[i]) : String(format: "%.0f %@", v, units[i])
    }
}

public enum CLIRender {
    public static func encoder(pretty: Bool = true) -> JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = pretty ? [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes] : [.sortedKeys, .withoutEscapingSlashes]
        return e
    }

    public static func json<T: Encodable>(_ value: T, pretty: Bool = true) -> String {
        guard let data = try? encoder(pretty: pretty).encode(value), let s = String(data: data, encoding: .utf8) else { return "null" }
        return s
    }

    /// RFC 4180 quoting.
    public static func csvField(_ s: String) -> String {
        guard s.contains(where: { $0 == "," || $0 == "\"" || $0 == "\n" || $0 == "\r" }) else { return s }
        return "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    public static func csv<R: CLIRow>(_ rows: [R]) -> String {
        var lines = [R.headers.map(csvField).joined(separator: ",")]
        lines += rows.map { $0.csvCells.map(csvField).joined(separator: ",") }
        return lines.joined(separator: "\n")
    }

    public static func table<R: CLIRow>(_ rows: [R]) -> String {
        let cells = rows.map(\.tableCells)
        var widths = R.headers.map(\.count)
        for r in cells { for (i, c) in r.enumerated() { widths[i] = max(widths[i], c.count) } }
        func line(_ r: [String]) -> String {
            var parts: [String] = []
            for (i, c) in r.enumerated() {
                let pad = String(repeating: " ", count: max(0, widths[i] - c.count))
                if R.rightAligned.contains(i) { parts.append(pad + c) } else { parts.append(i == r.count - 1 ? c : c + pad) }
            }
            return parts.joined(separator: "  ")
        }
        return ([line(R.headers)] + cells.map(line)).joined(separator: "\n")
    }

    public static func render<R: CLIRow>(_ rows: [R], as format: OutputFormat) -> String {
        switch format {
        case .table: table(rows)
        case .json: json(rows)
        case .csv: csv(rows)
        }
    }

    public static func sort(_ rows: [ProcessRow], by sort: PsSort) -> [ProcessRow] {
        switch sort {
        case .cpu: rows.sorted { ($0.cpuPercent, $1.pid) > ($1.cpuPercent, $0.pid) }
        case .mem: rows.sorted { ($0.memoryBytes, $1.pid) > ($1.memoryBytes, $0.pid) }
        case .pid: rows.sorted { $0.pid < $1.pid }
        case .name:
            rows.sorted {
                let c = $0.name.localizedCaseInsensitiveCompare($1.name)
                return c == .orderedSame ? $0.pid < $1.pid : c == .orderedAscending
            }
        }
    }
}
