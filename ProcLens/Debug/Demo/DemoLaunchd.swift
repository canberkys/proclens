#if DEBUG
import Foundation
import ProcLensCore

/// Demo launchd jobs. Plists are written into a scratch directory at launch (so the real scanner and parser run on
/// them unchanged), the code-signing lookup is answered from a table, and `launchctl` is replaced by canned output.
enum DemoLaunchd {
    struct Job {
        var label: String
        var scope: LaunchdScope
        var arguments: [String]
        var runAtLoad = true
        var keepAlive = false
        var disabled = false
        var interval: Int?
        var calendar: [String: Int]?
        var watchPaths: [String] = []
        var machServices: [String] = []
        /// Signer shown in the Startup tab ("Figma, Inc."); nil for Apple, ad-hoc and script jobs.
        var signer: String?
        var team: String?
        /// Name of a demo process whose pid is reported as running.
        var runningProcess: String?
    }

    static let jobs: [Job] = [
        Job(label: "com.figma.agent", scope: .userAgent,
            arguments: ["/Users/demo/Library/Application Support/Figma/FigmaAgent.app/Contents/MacOS/figma_agent"],
            keepAlive: true, signer: "Figma, Inc.", team: "DEMOFIG001", runningProcess: "figma_agent"),
        Job(label: "com.docker.helper", scope: .userAgent,
            arguments: ["/Applications/Docker.app/Contents/MacOS/com.docker.backend", "services"],
            keepAlive: true, signer: "Docker Inc", team: "DEMODOC001", runningProcess: "com.docker.backend"),
        Job(label: "homebrew.mxcl.postgresql@16", scope: .userAgent,
            arguments: ["/opt/homebrew/opt/postgresql@16/bin/postgres", "-D", "/opt/homebrew/var/postgresql@16"],
            keepAlive: true, signer: "Homebrew", runningProcess: "postgres"),
        Job(label: "homebrew.mxcl.redis", scope: .userAgent,
            arguments: ["/opt/homebrew/opt/redis/bin/redis-server", "/opt/homebrew/etc/redis.conf"],
            keepAlive: true, signer: "Homebrew", runningProcess: "redis-server"),
        Job(label: "com.microsoft.VSCode.ShipIt", scope: .userAgent,
            arguments: ["/Users/demo/Library/Caches/com.microsoft.VSCode.ShipIt/ShipIt", "com.microsoft.VSCode.ShipIt", "--launch"],
            runAtLoad: false, watchPaths: ["/Users/demo/Library/Caches/com.microsoft.VSCode.ShipIt/ShipItState.plist"],
            signer: "Microsoft Corporation", team: "DEMOMSF001"),
        Job(label: "com.example.backup", scope: .userAgent,
            arguments: ["/bin/bash", "/Users/demo/scripts/backup.sh"], runAtLoad: false, calendar: ["Hour": 2, "Minute": 30]),
        Job(label: "com.google.keystone.agent", scope: .userAgent,
            arguments: ["/Users/demo/Library/Google/GoogleSoftwareUpdate/GoogleSoftwareUpdate.bundle/Contents/Resources/GoogleSoftwareUpdateAgent.app/Contents/MacOS/GoogleSoftwareUpdateAgent", "-runMode", "ifneeded"],
            runAtLoad: true, disabled: true, interval: 3600, signer: "Google LLC", team: "DEMOGOO001"),
        Job(label: "com.microsoft.update.agent", scope: .globalAgent,
            arguments: ["/Library/Application Support/Microsoft/MAU2.0/Microsoft AutoUpdate.app/Contents/MacOS/Microsoft Update Assistant"],
            interval: 7200, signer: "Microsoft Corporation", team: "DEMOMSF001"),
        Job(label: "com.docker.vmnetd", scope: .globalDaemon,
            arguments: ["/Library/PrivilegedHelperTools/com.docker.vmnetd"], runAtLoad: false, keepAlive: true,
            machServices: ["com.docker.vmnetd"], signer: "Docker Inc", team: "DEMODOC001", runningProcess: "com.docker.vmnetd"),
        Job(label: "com.microsoft.autoupdate.helper", scope: .globalDaemon,
            arguments: ["/Library/PrivilegedHelperTools/com.microsoft.autoupdate.helper"], runAtLoad: false,
            machServices: ["com.microsoft.autoupdate.helper"], signer: "Microsoft Corporation", team: "DEMOMSF001"),
        Job(label: "com.apple.Dock.agent", scope: .appleAgent, arguments: ["/System/Library/CoreServices/Dock.app/Contents/MacOS/Dock"], keepAlive: true, runningProcess: "Dock"),
        Job(label: "com.apple.ControlCenter", scope: .appleAgent, arguments: ["/System/Library/CoreServices/ControlCenter.app/Contents/MacOS/ControlCenter"], keepAlive: true, runningProcess: "ControlCenter"),
        Job(label: "com.apple.sharingd", scope: .appleAgent, arguments: ["/usr/libexec/sharingd"], runAtLoad: false, machServices: ["com.apple.sharingd"], runningProcess: "sharingd"),
        Job(label: "com.apple.rapportd-user", scope: .appleAgent, arguments: ["/usr/libexec/rapportd"], runAtLoad: false, machServices: ["com.apple.rapportd-user"], runningProcess: "rapportd"),
        Job(label: "com.apple.mds", scope: .appleDaemon, arguments: ["/System/Library/Frameworks/CoreServices.framework/Frameworks/Metadata.framework/Versions/A/Support/mds"], keepAlive: true, runningProcess: "mds"),
        Job(label: "com.apple.bluetoothd", scope: .appleDaemon, arguments: ["/usr/sbin/bluetoothd"], keepAlive: true, runningProcess: "bluetoothd"),
        Job(label: "com.apple.logd", scope: .appleDaemon, arguments: ["/usr/libexec/logd"], keepAlive: true, runningProcess: "logd"),
        Job(label: "com.apple.coreaudiod", scope: .appleDaemon, arguments: ["/usr/sbin/coreaudiod"], runAtLoad: false, machServices: ["com.apple.audio.coreaudiod"], runningProcess: "coreaudiod"),
        Job(label: "com.apple.configd", scope: .appleDaemon, arguments: ["/usr/libexec/configd"], keepAlive: true, runningProcess: "configd"),
    ]

    private static func byProgram(_ path: String) -> Job? {
        jobs.first { $0.arguments.first == path }
    }

    static func signer(forProgram path: String) -> CodeSignStatus {
        guard let job = byProgram(path) else { return path.hasPrefix("/opt/homebrew") ? .adHoc : .unknown }
        if job.scope.isApple { return .apple }
        if let team = job.team { return .developerID(teamID: team, notarized: true) }
        return .adHoc
    }

    static func signerName(forProgram path: String) -> String? { byProgram(path)?.signer }

    private static func pid(of job: Job) -> Int? {
        job.runningProcess.flatMap { name in DemoWorld.processes.first { $0.name == name }.map { Int($0.pid) } }
    }

    // MARK: - Plists

    /// Where the job's plist appears to live (the real files sit in a scratch directory).
    static func displayPath(label: String, scope: LaunchdScope) -> String {
        let dir: String = switch scope {
        case .userAgent: "/Users/demo/Library/LaunchAgents"
        case .globalAgent: "/Library/LaunchAgents"
        case .globalDaemon: "/Library/LaunchDaemons"
        case .appleAgent: "/System/Library/LaunchAgents"
        case .appleDaemon: "/System/Library/LaunchDaemons"
        }
        return "\(dir)/\(label).plist"
    }

    static func relocated(_ items: [LaunchdItemStatus]) -> [LaunchdItemStatus] {
        items.map { status in
            var s = status
            s.item.plistPath = displayPath(label: s.item.label, scope: s.item.scope)
            return s
        }
    }

    static let root: URL = {
        let dir = URL(fileURLWithPath: "/private/tmp/proclens-demo", isDirectory: true)
        try? FileManager.default.removeItem(at: dir)
        for sub in ["UserAgents", "GlobalAgents", "GlobalDaemons", "AppleAgents", "AppleDaemons"] {
            try? FileManager.default.createDirectory(at: dir.appendingPathComponent(sub), withIntermediateDirectories: true)
        }
        for job in jobs {
            var plist: [String: Any] = ["Label": job.label, "ProgramArguments": job.arguments, "RunAtLoad": job.runAtLoad]
            if job.keepAlive { plist["KeepAlive"] = true }
            if job.disabled { plist["Disabled"] = true }
            if let interval = job.interval { plist["StartInterval"] = interval }
            if let calendar = job.calendar { plist["StartCalendarInterval"] = calendar }
            if !job.watchPaths.isEmpty { plist["WatchPaths"] = job.watchPaths }
            if !job.machServices.isEmpty { plist["MachServices"] = Dictionary(uniqueKeysWithValues: job.machServices.map { ($0, true) }) }
            if job.label.hasPrefix("homebrew") {
                plist["StandardOutPath"] = "/opt/homebrew/var/log/\(job.label).log"
            }
            let name: String = switch job.scope {
            case .userAgent: "UserAgents"
            case .globalAgent: "GlobalAgents"
            case .globalDaemon: "GlobalDaemons"
            case .appleAgent: "AppleAgents"
            case .appleDaemon: "AppleDaemons"
            }
            if let data = try? PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0) {
                try? data.write(to: dir.appendingPathComponent("\(name)/\(job.label).plist"))
            }
        }
        return dir
    }()

    static func service() -> LaunchdService {
        let dirs: [LaunchdDirectory] = [
            LaunchdDirectory(url: root.appendingPathComponent("UserAgents"), scope: .userAgent),
            LaunchdDirectory(url: root.appendingPathComponent("GlobalAgents"), scope: .globalAgent),
            LaunchdDirectory(url: root.appendingPathComponent("GlobalDaemons"), scope: .globalDaemon),
            LaunchdDirectory(url: root.appendingPathComponent("AppleAgents"), scope: .appleAgent),
            LaunchdDirectory(url: root.appendingPathComponent("AppleDaemons"), scope: .appleDaemon),
        ]
        let scanner = LaunchdPlistScanner(directories: dirs, uid: DemoWorld.userID, signer: { signer(forProgram: $0) })
        return LaunchdService(scanner: scanner, runner: DemoLaunchctlRunner(), privileged: UnavailablePrivilegedActions(),
                              uid: DemoWorld.userID)
    }
}

/// Canned `launchctl` output for the jobs above.
struct DemoLaunchctlRunner: LaunchctlRunning {
    func run(_ arguments: [String], timeout: TimeInterval) async throws -> LaunchctlOutput {
        func out(_ s: String) -> LaunchctlOutput { LaunchctlOutput(status: 0, stdout: s, stderr: "") }
        let gui = DemoLaunchd.jobs.filter { !$0.scope.isDaemon }
        let system = DemoLaunchd.jobs.filter { $0.scope.isDaemon }
        switch arguments.first {
        case "list":
            return out("PID\tStatus\tLabel\n" + gui.map { job in
                let pid = DemoLaunchd.jobs.firstIndex(where: { $0.label == job.label }).flatMap { _ in
                    job.runningProcess.flatMap { n in DemoWorld.processes.first { $0.name == n }.map { String($0.pid) } }
                } ?? "-"
                return "\(pid)\t0\t\(job.label)"
            }.joined(separator: "\n") + "\n")
        case "print-disabled":
            let target = arguments.dropFirst().first ?? ""
            let disabled = target == "system" ? [] : gui.filter(\.disabled).map(\.label)
            return out("disabled services = {\n" + disabled.map { "\t\"\($0)\" => disabled" }.joined(separator: "\n") + "\n}\n")
        case "print":
            let target = arguments.dropFirst().first ?? ""
            if target == "system" {
                return out("system = {\n\tservices = {\n" + system.map { job in
                    let pid = job.runningProcess.flatMap { n in DemoWorld.processes.first { $0.name == n }.map { Int($0.pid) } } ?? 0
                    return "\t\t\(String(format: "%6d", pid)) 0 \t\(job.label)"
                }.joined(separator: "\n") + "\n\t}\n}\n")
            }
            let label = target.split(separator: "/").last.map(String.init) ?? ""
            guard let job = DemoLaunchd.jobs.first(where: { $0.label == label }) else {
                return LaunchctlOutput(status: 113, stdout: "", stderr: "Could not find service \"\(label)\" in domain for \(target)")
            }
            let pid = job.runningProcess.flatMap { n in DemoWorld.processes.first { $0.name == n }.map { Int($0.pid) } }
            var text = "\(target) = {\n\tactive count = \(pid == nil ? 0 : 1)\n\tpath = \(DemoLaunchd.displayPath(label: job.label, scope: job.scope))\n\ttype = LaunchAgent\n"
            text += "\tstate = \(pid == nil ? "not running" : "running")\n\tprogram = \(job.arguments[0])\n\targuments = {\n"
            text += job.arguments.map { "\t\t\($0)\n" }.joined() + "\t}\n\tdomain = \(target.split(separator: "/").first.map(String.init) ?? "gui/501") [100003]\n"
            if let pid { text += "\tpid = \(pid)\n\truns = 1\n\tlast exit code = (never exited)\n" } else { text += "\truns = 0\n\tlast exit code = 0\n" }
            text += "\timmediate reason = \(job.keepAlive ? "ineligible" : "inefficient")\n}\n"
            return out(text)
        default:
            return LaunchctlOutput(status: 0, stdout: "", stderr: "")
        }
    }
}
#endif
