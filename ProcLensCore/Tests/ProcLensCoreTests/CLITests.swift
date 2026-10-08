import Foundation
import Testing
@testable import ProcLensCLIKit
@testable import ProcLensCore

@Suite struct CLIParserTests {
    @Test func basics() throws {
        #expect(try CLIParser.parse([]) == .help)
        #expect(try CLIParser.parse(["--help"]) == .help)
        #expect(try CLIParser.parse(["--version"]) == .version)
        #expect(try CLIParser.parse(["ps"]) == .ps(sort: .cpu, limit: nil, format: .table))
        #expect(try CLIParser.parse(["ps", "--sort", "mem", "--limit", "5", "--json"]) == .ps(sort: .mem, limit: 5, format: .json))
        #expect(try CLIParser.parse(["ps", "--sort=name", "--limit=3", "--csv"]) == .ps(sort: .name, limit: 3, format: .csv))
        #expect(try CLIParser.parse(["top"]) == .top(interval: 2, count: nil, limit: 10, json: false))
        #expect(try CLIParser.parse(["top", "--interval", "0.5", "--count", "3", "--json"]) == .top(interval: 0.5, count: 3, limit: 10, json: true))
        #expect(try CLIParser.parse(["ports", "--csv"]) == .ports(format: .csv))
        #expect(try CLIParser.parse(["kill", "123"]) == .kill(pid: 123, force: false, tree: false, yes: false))
        #expect(try CLIParser.parse(["kill", "--force", "--tree", "-y", "123"]) == .kill(pid: 123, force: true, tree: true, yes: true))
        #expect(try CLIParser.parse(["launchd", "--json"]) == .launchd(json: true))
        #expect(try CLIParser.parse(["system"]) == .system(json: false))
    }

    @Test func errors() {
        for bad in [["bogus"], ["ps", "--sort", "size"], ["ps", "--limit", "0"], ["ps", "--limit"], ["ps", "--json", "--csv"],
                    ["ps", "--nope"], ["ps", "extra"], ["kill"], ["kill", "abc"], ["kill", "1", "2"], ["top", "--interval", "0"],
                    ["system", "--csv"], ["ports", "--json=1"]] {
            #expect(throws: UsageError.self, "\(bad)") { try CLIParser.parse(bad) }
        }
    }

    @Test func helpMentionsEveryCommandAndExitCodes() {
        for word in ["ps", "top", "ports", "kill", "launchd", "system", "--version", "EXIT CODES"] {
            #expect(CLIHelp.text.contains(word))
        }
    }
}

@Suite struct CLIFormatTests {
    let rows = [
        ProcessRow(pid: 42, name: "Foo, \"Bar\"", user: "me", cpuPercent: 12.345, memoryBytes: 1_572_864_000, threads: 3, arch: "arm64", translated: false),
        ProcessRow(pid: 7, name: "zed", user: "root", cpuPercent: 0, memoryBytes: 2048, threads: 1, arch: "x86_64", translated: true),
    ]

    @Test func csvHasHeaderAndQuoting() {
        let lines = CLIRender.csv(rows).split(separator: "\n").map(String.init)
        #expect(lines[0] == "PID,NAME,USER,CPU%,MEM,THREADS,ARCH")
        #expect(lines[1] == "42,\"Foo, \"\"Bar\"\"\",me,12.3,1572864000,3,arm64")
        #expect(lines[2] == "7,zed,root,0.0,2048,1,x86_64")
        #expect(CLIRender.csv([ProcessRow]()) == "PID,NAME,USER,CPU%,MEM,THREADS,ARCH")
    }

    @Test func jsonIsStableSortedAndRoundTrips() throws {
        let a = CLIRender.json(rows), b = CLIRender.json(rows)
        #expect(a == b)
        let firstKeys = a.components(separatedBy: "\n").filter { $0.hasPrefix("    \"") }.prefix(8).map { $0.split(separator: "\"")[0...1].last! }
        #expect(firstKeys == ["arch", "cpuPercent", "memoryBytes", "name", "pid", "threads", "translated", "user"])
        let back = try JSONDecoder().decode([ProcessRow].self, from: Data(a.utf8))
        #expect(back == rows)
        #expect(!CLIRender.json(rows, pretty: false).contains("\n"))
    }

    @Test func tableAlignsColumns() {
        let t = CLIRender.table(rows).split(separator: "\n").map(String.init)
        #expect(t.count == 3)
        #expect(t[0].hasPrefix("PID"))
        #expect(t[1].contains("1.5 GB"))
        #expect(t[2].contains("x86_64 (Rosetta)"))
        #expect(t[1].count >= t[0].count - 20)
    }

    @Test func sorting() {
        #expect(CLIRender.sort(rows, by: .pid).map(\.pid) == [7, 42])
        #expect(CLIRender.sort(rows, by: .mem).map(\.pid) == [42, 7])
        #expect(CLIRender.sort(rows, by: .cpu).map(\.pid) == [42, 7])
        #expect(CLIRender.sort(rows, by: .name).map(\.name) == ["Foo, \"Bar\"", "zed"])
    }

    @Test func bytes() {
        #expect(Bytes.format(0) == "0 B")
        #expect(Bytes.format(2048) == "2 KB")
        #expect(Bytes.format(5 << 20) == "5 MB")
        #expect(Bytes.format(3 << 30) == "3.0 GB")
    }

    @Test func systemReportEncodes() throws {
        let s = Synth.snapshot(cpu: 0.456, memoryUsed: 4 << 30, processes: Synth.table([Synth.process(1, cpu: 0, memory: 0)]),
                               disk: 100, network: 50, gpu: 0.25)
        let r = SystemReport(s)
        #expect(r.cpu?.totalPercent == 45.6)
        #expect(r.processCount == 1)
        #expect(r.gpu?.utilizationPercent == 25)
        #expect(r.text().contains("Memory"))
        let json = CLIRender.json(r)
        #expect(try JSONDecoder().decode(SystemReport.self, from: Data(json.utf8)) == r)
    }

    @Test func portAndLaunchdRows() {
        let p = PortRow(port: 3000, proto: "tcp", address: "::1", loopbackOnly: true, pid: 9, process: "node", framework: "Vite", category: "web")
        #expect(CLIRender.csv([p]).hasSuffix("3000,tcp,::1,9,node,Vite"))
        let l = LaunchdRow(label: "a.b", scope: "userAgent", domain: "gui/501", enabled: true, loaded: true, running: false,
                           pid: nil, lastExitStatus: 0, program: "/bin/x")
        #expect(CLIRender.table([l]).contains("loaded"))
        #expect(CLIRender.csv([l]).hasSuffix("a.b,userAgent,true,loaded,,0,/bin/x"))
    }
}

@Suite struct CLIKillTests {
    final class Controller: ProcessController, @unchecked Sendable {
        let lock = NSLock()
        var alive: Set<pid_t>
        var sent: [(Int32, pid_t)] = []
        let starts: [pid_t: UInt64]
        init(alive: Set<pid_t>, starts: [pid_t: UInt64]) { self.alive = alive; self.starts = starts }
        func startTime(pid: pid_t) -> UInt64? { lock.withLock { alive.contains(pid) ? starts[pid] : nil } }
        func send(_ signal: Int32, to pid: pid_t) -> Int32 {
            lock.withLock { sent.append((signal, pid)); alive.remove(pid) }
            return 0
        }
        func isAlive(pid: pid_t) -> Bool { lock.withLock { alive.contains(pid) } }
    }

    final class Sink: @unchecked Sendable {
        let lock = NSLock()
        var out: [String] = [], err: [String] = []
    }

    func io(_ sink: Sink, interactive: Bool = false, answer: Bool = false) -> CLIIO {
        CLIIO(out: { s in sink.lock.withLock { sink.out.append(s) } }, err: { s in sink.lock.withLock { sink.err.append(s) } },
              isInteractive: interactive, confirm: { _ in answer })
    }

    @Test func refusesCriticalProcess() async {
        let p = Synth.process(50, cpu: 0, memory: 0, name: "WindowServer")
        let c = Controller(alive: [50], starts: [50: p.id.startTime])
        let sink = Sink()
        let code = await CLICommands.performKill(sample: p, table: Synth.table([p]), force: false, tree: false, yes: true,
                                                 io: io(sink), controller: c)
        #expect(code == CLIExit.refused)
        #expect(c.sent.isEmpty)
    }

    @Test func requiresConfirmationWithoutYes() async {
        let p = Synth.process(60, cpu: 0, memory: 0, name: "sleep")
        let c = Controller(alive: [60], starts: [60: p.id.startTime])
        let sink = Sink()
        let code = await CLICommands.performKill(sample: p, table: Synth.table([p]), force: false, tree: false, yes: false,
                                                 io: io(sink), controller: c)
        #expect(code == CLIExit.error)
        #expect(c.sent.isEmpty)
        let declined = await CLICommands.performKill(sample: p, table: Synth.table([p]), force: false, tree: false, yes: false,
                                                     io: io(sink, interactive: true, answer: false), controller: c)
        #expect(declined == CLIExit.error)
        #expect(c.sent.isEmpty)
        let accepted = await CLICommands.performKill(sample: p, table: Synth.table([p]), force: false, tree: false, yes: false,
                                                     io: io(sink, interactive: true, answer: true), controller: c)
        #expect(accepted == CLIExit.ok)
        #expect(c.sent.first?.0 == SIGTERM)
    }

    @Test func forceSendsSigkill() async {
        let p = Synth.process(61, cpu: 0, memory: 0, name: "sleep")
        let c = Controller(alive: [61], starts: [61: p.id.startTime])
        let code = await CLICommands.performKill(sample: p, table: Synth.table([p]), force: true, tree: false, yes: true,
                                                 io: io(Sink()), controller: c)
        #expect(code == CLIExit.ok)
        #expect(c.sent.first?.0 == SIGKILL)
    }

    @Test func treeKillsChildrenFirst() async {
        var parent = Synth.process(70, cpu: 0, memory: 0, name: "npm")
        parent.ppid = 1
        var child = Synth.process(71, cpu: 0, memory: 0, name: "node")
        child.ppid = 70
        let c = Controller(alive: [70, 71], starts: [70: parent.id.startTime, 71: child.id.startTime])
        let sink = Sink()
        let code = await CLICommands.performKill(sample: parent, table: Synth.table([parent, child]), force: false, tree: true,
                                                 yes: true, io: io(sink), controller: c)
        #expect(code == CLIExit.ok)
        #expect(c.sent.map(\.1) == [71, 70])
        #expect(sink.out.count == 2)
    }
}
