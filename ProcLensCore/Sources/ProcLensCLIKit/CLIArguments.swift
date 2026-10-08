import Foundation

public let proclensVersion = "0.1.0"

public enum OutputFormat: String, Sendable, Equatable { case table, json, csv }

public enum PsSort: String, Sendable, Equatable { case cpu, mem, pid, name }

/// Exit codes of the `proclens` executable.
public enum CLIExit {
    public static let ok: Int32 = 0
    public static let error: Int32 = 1
    public static let usage: Int32 = 2
    public static let refused: Int32 = 3
}

public struct UsageError: Error, Equatable, CustomStringConvertible {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var description: String { message }
}

public enum CLICommand: Equatable, Sendable {
    case ps(sort: PsSort, limit: Int?, format: OutputFormat)
    case top(interval: Double, count: Int?, limit: Int, json: Bool)
    case ports(format: OutputFormat)
    case kill(pid: Int32, force: Bool, tree: Bool, yes: Bool)
    case launchd(json: Bool)
    case system(json: Bool)
    case version
    case help
}

public enum CLIParser {
    /// Parses the arguments after the executable name. Accepts `--opt value` and `--opt=value`.
    public static func parse(_ args: [String]) throws -> CLICommand {
        guard let first = args.first else { return .help }
        let rest = Array(args.dropFirst())
        switch first {
        case "--help", "-h", "help": return .help
        case "--version", "-V", "version": return .version
        case "ps":
            var o = try Options(rest, values: ["--sort", "--limit"], flags: ["--json", "--csv"])
            let format = try o.format()
            let sort = try o.value("--sort").map { raw -> PsSort in
                guard let s = PsSort(rawValue: raw) else { throw UsageError("invalid --sort '\(raw)' (cpu, mem, pid, name)") }
                return s
            } ?? .cpu
            let limit = try o.int("--limit", min: 1)
            try o.finish()
            return .ps(sort: sort, limit: limit, format: format)
        case "top":
            var o = try Options(rest, values: ["--interval", "--count", "--limit"], flags: ["--json"])
            let interval = try o.double("--interval", min: 0.1) ?? 2
            let count = try o.int("--count", min: 1)
            let limit = try o.int("--limit", min: 1) ?? 10
            let json = o.flag("--json")
            try o.finish()
            return .top(interval: interval, count: count, limit: limit, json: json)
        case "ports":
            var o = try Options(rest, values: [], flags: ["--json", "--csv"])
            let format = try o.format()
            try o.finish()
            return .ports(format: format)
        case "kill":
            var o = try Options(rest, values: [], flags: ["--force", "--tree", "--yes", "-y"])
            let force = o.flag("--force"), tree = o.flag("--tree"), yes = o.flag("--yes") || o.flag("-y")
            let positional = o.positional
            guard positional.count == 1 else { throw UsageError("kill needs exactly one <pid>") }
            guard let pid = Int32(positional[0]), pid >= 0 else { throw UsageError("invalid pid '\(positional[0])'") }
            try o.finish(allowPositional: true)
            return .kill(pid: pid, force: force, tree: tree, yes: yes)
        case "launchd":
            var o = try Options(rest, values: [], flags: ["--json"])
            let json = o.flag("--json")
            try o.finish()
            return .launchd(json: json)
        case "system":
            var o = try Options(rest, values: [], flags: ["--json"])
            let json = o.flag("--json")
            try o.finish()
            return .system(json: json)
        default:
            throw UsageError("unknown command '\(first)'")
        }
    }

    /// Minimal option scanner: tracks which options were consumed so unknown ones are reported.
    struct Options {
        private(set) var positional: [String] = []
        private var values: [String: String] = [:]
        private var flags: Set<String> = []
        private var consumed: Set<String> = []

        init(_ args: [String], values valueNames: Set<String>, flags flagNames: Set<String>) throws {
            var i = 0
            while i < args.count {
                let a = args[i]
                if a.hasPrefix("-"), a != "-" {
                    var name = a, inline: String?
                    if a.hasPrefix("--"), let eq = a.firstIndex(of: "=") {
                        name = String(a[..<eq])
                        inline = String(a[a.index(after: eq)...])
                    }
                    if valueNames.contains(name) {
                        if let inline { values[name] = inline } else {
                            guard i + 1 < args.count else { throw UsageError("\(name) needs a value") }
                            i += 1
                            values[name] = args[i]
                        }
                    } else if flagNames.contains(name), inline == nil {
                        flags.insert(name)
                    } else {
                        throw UsageError("unknown option '\(a)'")
                    }
                } else {
                    positional.append(a)
                }
                i += 1
            }
        }

        mutating func flag(_ name: String) -> Bool { consumed.insert(name); return flags.contains(name) }
        mutating func value(_ name: String) -> String? { consumed.insert(name); return values[name] }

        mutating func int(_ name: String, min: Int) throws -> Int? {
            guard let raw = value(name) else { return nil }
            guard let n = Int(raw), n >= min else { throw UsageError("\(name) must be an integer >= \(min)") }
            return n
        }

        mutating func double(_ name: String, min: Double) throws -> Double? {
            guard let raw = value(name) else { return nil }
            guard let d = Double(raw), d.isFinite, d >= min else { throw UsageError("\(name) must be a number >= \(min)") }
            return d
        }

        mutating func format() throws -> OutputFormat {
            let json = flag("--json"), csv = flag("--csv")
            if json && csv { throw UsageError("--json and --csv are mutually exclusive") }
            return json ? .json : csv ? .csv : .table
        }

        func finish(allowPositional: Bool = false) throws {
            if !allowPositional, let p = positional.first { throw UsageError("unexpected argument '\(p)'") }
        }
    }
}

public enum CLIHelp {
    public static let text = """
    proclens \(proclensVersion) - process, port and launchd inspector (shares ProcLensCore with the ProcLens app)

    USAGE: proclens <command> [options]

    COMMANDS
      ps       [--sort cpu|mem|pid|name] [--limit N] [--json|--csv]
               Process table from two samples 1 s apart.
      top      [--interval S] [--count N] [--limit N] [--json]
               Stream snapshots every S seconds (default 2); --count N stops after N; --json prints one object per line.
      ports    [--json|--csv]
               Listening TCP/UDP ports with owner and dev-server classification.
      kill     <pid> [--force] [--tree] [--yes]
               SIGTERM (or SIGKILL with --force); --tree also ends all descendants. Asks on a TTY unless --yes.
               Refuses pid 0/1, critical system processes and proclens itself.
      launchd  [--json]
               Launch agents/daemons with enabled/loaded/running state.
      system   [--json]
               CPU, memory, GPU, disk and network snapshot.

    OPTIONS
      --version, -V   Print the version.
      --help, -h      Print this help.

    EXIT CODES
      0 ok   1 error   2 usage error   3 refused (protected process)
    """
}
