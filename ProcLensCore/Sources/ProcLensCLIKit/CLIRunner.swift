import Darwin
import Foundation
import ProcLensCore

/// Everything a command needs from the terminal; replaced in tests.
public struct CLIIO: Sendable {
    public var out: @Sendable (String) -> Void
    public var err: @Sendable (String) -> Void
    /// stdin is a TTY, so a confirmation prompt can be answered.
    public var isInteractive: Bool
    public var confirm: @Sendable (String) -> Bool

    public init(out: @escaping @Sendable (String) -> Void, err: @escaping @Sendable (String) -> Void,
                isInteractive: Bool, confirm: @escaping @Sendable (String) -> Bool) {
        self.out = out
        self.err = err
        self.isInteractive = isInteractive
        self.confirm = confirm
    }

    public static let live = CLIIO(
        out: { FileHandle.standardOutput.write(Data(($0 + "\n").utf8)) },
        err: { FileHandle.standardError.write(Data(($0 + "\n").utf8)) },
        isInteractive: isatty(STDIN_FILENO) != 0,
        confirm: { prompt in
            FileHandle.standardError.write(Data((prompt + " [y/N] ").utf8))
            guard let answer = readLine() else { return false }
            return ["y", "yes"].contains(answer.trimmingCharacters(in: .whitespaces).lowercased())
        })
}

public enum CLIMain {
    /// Entry point used by the `proclens` executable. Returns the process exit code.
    public static func run(arguments: [String], io: CLIIO = .live) async -> Int32 {
        let command: CLICommand
        do {
            command = try CLIParser.parse(arguments)
        } catch let e as UsageError {
            io.err("proclens: \(e.message)\nTry 'proclens --help'.")
            return CLIExit.usage
        } catch {
            io.err("proclens: \(error)")
            return CLIExit.usage
        }
        return await execute(command, io: io)
    }

    public static func execute(_ command: CLICommand, io: CLIIO) async -> Int32 {
        switch command {
        case .help:
            io.out(CLIHelp.text)
            return CLIExit.ok
        case .version:
            io.out("proclens \(proclensVersion)")
            return CLIExit.ok
        case .ps(let sort, let limit, let format):
            return await CLICommands.ps(sort: sort, limit: limit, format: format, io: io)
        case .top(let interval, let count, let limit, let json):
            return await CLICommands.top(interval: interval, count: count, limit: limit, json: json, io: io)
        case .ports(let format):
            return await CLICommands.ports(format: format, io: io)
        case .kill(let pid, let force, let tree, let yes):
            return await CLICommands.kill(pid: pid, force: force, tree: tree, yes: yes, io: io)
        case .launchd(let json):
            return await CLICommands.launchd(json: json, io: io)
        case .system(let json):
            return await CLICommands.system(json: json, io: io)
        }
    }
}

enum CLICommands {
    static func makeSampler() -> Sampler {
        let host = LiveHostSource()
        let ioreg = LiveIORegistrySource()
        return Sampler(cpu: CPUCollector(source: host), memory: MemoryCollector(source: host),
                       processes: ProcessCollector(source: LiveProcessSource()), gpu: GPUCollector(source: ioreg),
                       disk: DiskCollector(source: ioreg), network: NetworkCollector(source: LiveNetworkSource()))
    }

    /// Second sample of a process collector one second after the first (CPU needs a delta).
    static func sampleProcesses(_ collector: ProcessCollector) async throws -> ProcessTable {
        _ = try await collector.sample(at: .now)
        try await Task.sleep(for: .seconds(1))
        return try await collector.sample(at: .now)
    }

    static func ps(sort: PsSort, limit: Int?, format: OutputFormat, io: CLIIO) async -> Int32 {
        do {
            let table = try await sampleProcesses(ProcessCollector(source: LiveProcessSource()))
            let users = UserNames()
            var rows = CLIRender.sort(table.processes.values.map { ProcessRow($0, user: users.name(for: $0.uid)) }, by: sort)
            if let limit { rows = Array(rows.prefix(limit)) }
            io.out(CLIRender.render(rows, as: format))
            return CLIExit.ok
        } catch {
            io.err("proclens: \(error)")
            return CLIExit.error
        }
    }

    static func top(interval: Double, count: Int?, limit: Int, json: Bool, io: CLIIO) async -> Int32 {
        let sampler = makeSampler()
        let users = UserNames()
        _ = await sampler.tickOnce()
        var frames = 0
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(interval))
            let snap = await sampler.tickOnce()
            let rows = CLIRender.sort((snap.processes?.processes.values ?? [:].values).map {
                ProcessRow($0, user: users.name(for: $0.uid))
            }, by: .cpu).prefix(limit)
            let report = SystemReport(snap)
            let time = ISO8601DateFormatter().string(from: Date())
            if json {
                io.out(CLIRender.json(TopFrame(time: time, system: report, processes: Array(rows)), pretty: false))
            } else {
                io.out("proclens top  \(time)\n\(report.text())\n\n\(CLIRender.table(Array(rows)))\n")
            }
            frames += 1
            if let count, frames >= count { break }
        }
        return CLIExit.ok
    }

    static func ports(format: OutputFormat, io: CLIIO) async -> Int32 {
        do {
            let pc = ProcessCollector(source: LiveProcessSource())
            let table = try await pc.sample(at: .now)
            let found = await ListeningPortCollector().scan(table: table)
            var rows: [PortRow] = []
            var commandLines: [ProcessID: String] = [:]
            for p in found.sorted(by: { ($0.port, $0.pid) < ($1.port, $1.pid) }) {
                let name = table.processes[p.processID]?.name ?? "?"
                if commandLines[p.processID] == nil {
                    commandLines[p.processID] = (try? await pc.arguments(for: p.processID))?.arguments.joined(separator: " ") ?? ""
                }
                let proc = table.processes[p.processID]
                let match = DevServerClassifier.shared.classify(port: p, processName: name, commandLine: commandLines[p.processID] ?? "",
                                                                executablePath: proc?.path, uid: proc?.uid)
                rows.append(PortRow(port: Int(p.port), proto: p.proto.rawValue, address: p.address, loopbackOnly: p.isLoopbackOnly,
                                    pid: p.pid, process: name, framework: match.framework, category: match.category.rawValue))
            }
            io.out(CLIRender.render(rows, as: format))
            return CLIExit.ok
        } catch {
            io.err("proclens: \(error)")
            return CLIExit.error
        }
    }

    static func system(json: Bool, io: CLIIO) async -> Int32 {
        let sampler = makeSampler()
        _ = await sampler.tickOnce()
        try? await Task.sleep(for: .seconds(1))
        let report = SystemReport(await sampler.tickOnce())
        io.out(json ? CLIRender.json(report) : report.text())
        return CLIExit.ok
    }

    static func launchd(json: Bool, io: CLIIO) async -> Int32 {
        let items = await LaunchdService().items()
        let rows = items.map(LaunchdRow.init).sorted { $0.label.localizedCaseInsensitiveCompare($1.label) == .orderedAscending }
        if json {
            io.out(CLIRender.json(rows))
        } else {
            let running = rows.filter(\.running).count, loaded = rows.filter(\.loaded).count
            let disabled = rows.filter { !$0.enabled }.count
            io.out("\(rows.count) items: \(running) running, \(loaded) loaded, \(disabled) disabled\n")
            io.out(CLIRender.table(rows))
        }
        return CLIExit.ok
    }

    static func kill(pid: Int32, force: Bool, tree: Bool, yes: Bool, io: CLIIO) async -> Int32 {
        if pid <= 1 {
            io.err("proclens: refused: PID \(pid) is critical to macOS and cannot be ended.")
            return CLIExit.refused
        }
        let table: ProcessTable
        do {
            table = try await ProcessCollector(source: LiveProcessSource()).sample(at: .now)
        } catch {
            io.err("proclens: \(error)")
            return CLIExit.error
        }
        guard let sample = table.processes.values.first(where: { $0.pid == pid }) else {
            io.err("proclens: no such process: \(pid)")
            return CLIExit.error
        }
        return await performKill(sample: sample, table: table, force: force, tree: tree, yes: yes, io: io,
                                 controller: LiveProcessController())
    }

    /// Separated from `kill` so tests can inject a controller and table.
    static func performKill(sample: ProcessSample, table: ProcessTable, force: Bool, tree: Bool, yes: Bool, io: CLIIO,
                            controller: any ProcessController, policy: ProtectionPolicy = ProtectionPolicy(),
                            ownPID: pid_t = getpid()) async -> Int32 {
        if case .refused(let reason) = policy.verdict(for: sample, ownPID: ownPID) {
            io.err("proclens: refused: \(reason)")
            return CLIExit.refused
        }
        let descendants = tree ? ProcessTree(table: table).descendants(of: sample.id).count : 0
        if !yes {
            guard io.isInteractive else {
                io.err("proclens: confirmation required; re-run with --yes.")
                return CLIExit.error
            }
            let extra = tree ? " and \(descendants) child process(es)" : ""
            let verb = force ? "SIGKILL" : "SIGTERM"
            guard io.confirm("\(verb) \(sample.name) (pid \(sample.pid))\(extra)?") else {
                io.err("proclens: cancelled.")
                return CLIExit.error
            }
        }

        if tree {
            let killer = TreeKiller(controller: controller, policy: policy, ownPID: ownPID)
            let results = await killer.kill(root: sample.id, in: table, gracePeriod: force ? .zero : .seconds(3))
            var ok = true
            for r in results {
                io.out("\(r.id.pid)\t\(r.name)\t\(describe(r.outcome))")
                switch r.outcome {
                case .terminated, .killed, .refused: break
                default: ok = false
                }
            }
            return ok ? CLIExit.ok : CLIExit.error
        }

        guard controller.startTime(pid: sample.pid) == sample.id.startTime, controller.isAlive(pid: sample.pid) else {
            io.err("proclens: process \(sample.pid) is already gone.")
            return CLIExit.error
        }
        let err = controller.send(force ? SIGKILL : SIGTERM, to: sample.pid)
        if err != 0 {
            io.err("proclens: cannot signal \(sample.pid): \(String(cString: strerror(err)))")
            return CLIExit.error
        }
        let deadline = ContinuousClock.now.advanced(by: force ? .seconds(2) : .seconds(3))
        while controller.isAlive(pid: sample.pid), ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(50))
        }
        if controller.isAlive(pid: sample.pid) {
            io.err("proclens: \(sample.name) (\(sample.pid)) is still running; try --force.")
            return CLIExit.error
        }
        io.out("\(sample.pid)\t\(sample.name)\t\(force ? "killed" : "terminated")")
        return CLIExit.ok
    }

    static func describe(_ o: KillOutcome) -> String {
        switch o {
        case .terminated: "terminated"
        case .killed: "killed"
        case .refused(let reason): "refused: \(reason)"
        case .alreadyGone: "already gone"
        case .failed(let e): "failed: \(String(cString: strerror(e)))"
        }
    }
}

/// uid -> user name, cached.
final class UserNames: @unchecked Sendable {
    private var cache: [uid_t: String] = [:]
    func name(for uid: uid_t) -> String {
        if let n = cache[uid] { return n }
        let n = getpwuid(uid).map { String(cString: $0.pointee.pw_name) } ?? String(uid)
        cache[uid] = n
        return n
    }
}
