import Foundation
import ProcLensHelperProtocol
import Testing
@testable import ProcLensCore

final class MockRunner: LaunchctlRunning, @unchecked Sendable {
    private let lock = NSLock()
    private var _calls: [[String]] = []
    var responses: [String: LaunchctlOutput] = [:]
    var calls: [[String]] { lock.withLock { _calls } }

    func run(_ arguments: [String], timeout: TimeInterval) async throws -> LaunchctlOutput {
        lock.withLock { _calls.append(arguments) }
        return responses[arguments.joined(separator: " ")] ?? LaunchctlOutput(status: 0, stdout: "", stderr: "")
    }
}

actor RecordingPrivileged: PrivilegedLaunchdActions {
    var received: [(LaunchdAction, String, String?)] = []
    func performSystemAction(_ action: LaunchdAction, label: String, plistPath: String?) async throws {
        received.append((action, label, plistPath))
    }
}

@Suite struct LaunchdServiceTests {
    private func item(_ label: String, scope: LaunchdScope, disabled: Bool = false) -> LaunchdItem {
        LaunchdItem(
            label: label, plistPath: "/tmp/\(label).plist", scope: scope, domain: scope.domain(uid: 501),
            program: "/bin/true", programArguments: ["/bin/true"], bundleProgram: nil, runAtLoad: false, keepAlive: .never,
            plistDisabled: disabled, startInterval: nil, calendarIntervals: [], watchPaths: [], queueDirectories: [],
            machServices: [], hasSockets: false, standardOutPath: nil, standardErrorPath: nil, workingDirectory: nil,
            userName: nil, associatedBundleIdentifiers: [], vendor: nil, signing: nil)
    }

    @Test func mergeRules() {
        let running = LaunchctlListEntry(label: "a", pid: 42, status: 0)
        let merged = LaunchdService.merge(item: item("a", scope: .userAgent), override: nil, entry: running)
        #expect(merged.isEnabled && merged.isLoaded && merged.pid == 42 && merged.lastExitStatus == 0)

        // Override database wins over the plist key in both directions.
        #expect(LaunchdService.merge(item: item("a", scope: .userAgent, disabled: true), override: false, entry: nil).isEnabled)
        #expect(!LaunchdService.merge(item: item("a", scope: .userAgent), override: true, entry: nil).isEnabled)
        #expect(!LaunchdService.merge(item: item("a", scope: .userAgent, disabled: true), override: nil, entry: nil).isEnabled)
        #expect(!LaunchdService.merge(item: item("a", scope: .userAgent), override: nil, entry: nil).isLoaded)
    }

    @Test func snapshotMergesPlistsWithLaunchctl() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("proclens-svc-\(UUID().uuidString)")
        let agents = root.appendingPathComponent("agents"), daemons = root.appendingPathComponent("daemons")
        for dir in [agents, daemons] { try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true) }
        defer { try? FileManager.default.removeItem(at: root) }
        func write(_ label: String, to dir: URL) throws {
            let data = try PropertyListSerialization.data(fromPropertyList: ["Label": label, "Program": "/bin/true"], format: .xml, options: 0)
            try data.write(to: dir.appendingPathComponent("\(label).plist"))
        }
        try write("com.example.agent", to: agents)
        try write("com.example.off", to: agents)
        try write("com.example.daemon", to: daemons)

        let runner = MockRunner()
        runner.responses["list"] = LaunchctlOutput(status: 0, stdout: "PID\tStatus\tLabel\n321\t0\tcom.example.agent\n-\t1\tcom.example.off\n", stderr: "")
        runner.responses["print-disabled gui/501"] = LaunchctlOutput(status: 0, stdout: "disabled services = {\n\t\t\"com.example.off\" => disabled\n}\n", stderr: "")
        runner.responses["print-disabled system"] = LaunchctlOutput(status: 0, stdout: "", stderr: "")
        runner.responses["print system"] = LaunchctlOutput(
            status: 0, stdout: "system = {\n\tservices = {\n\t\t     900      0 \tcom.example.daemon\n\t}\n}\n", stderr: "")

        let service = LaunchdService(
            scanner: LaunchdPlistScanner(
                directories: [LaunchdDirectory(url: agents, scope: .userAgent), LaunchdDirectory(url: daemons, scope: .globalDaemon)],
                uid: 501, signer: { _ in .unknown }),
            runner: runner, uid: 501)
        let snapshot = await service.snapshot()
        #expect(snapshot.warnings.isEmpty)
        let byLabel = Dictionary(uniqueKeysWithValues: snapshot.items.map { ($0.item.label, $0) })
        #expect(byLabel["com.example.agent"]?.pid == 321)
        #expect(byLabel["com.example.agent"]?.isEnabled == true)
        #expect(byLabel["com.example.off"]?.isEnabled == false)
        #expect(byLabel["com.example.off"]?.isLoaded == true)
        #expect(byLabel["com.example.off"]?.lastExitStatus == 1)
        #expect(byLabel["com.example.daemon"]?.pid == 900)
        #expect(byLabel["com.example.daemon"]?.isLoaded == true)
    }

    @Test func failingLaunchctlBecomesWarning() async {
        struct Failing: LaunchctlRunning {
            func run(_ arguments: [String], timeout: TimeInterval) async throws -> LaunchctlOutput {
                LaunchctlOutput(status: 1, stdout: "", stderr: "boom")
            }
        }
        let service = LaunchdService(scanner: LaunchdPlistScanner(directories: [], uid: 501), runner: Failing(), uid: 501)
        let snapshot = await service.snapshot()
        #expect(snapshot.warnings.count == 4)
        #expect(snapshot.items.isEmpty)
    }

    @Test func guiActionsBuildExpectedCommands() async throws {
        let runner = MockRunner()
        let service = LaunchdService(scanner: LaunchdPlistScanner(directories: [], uid: 501), runner: runner, uid: 501)
        let it = item("com.example.agent", scope: .userAgent)
        try await service.enable(it)
        try await service.disable(it)
        try await service.bootstrap(it)
        try await service.bootout(it)
        try await service.kickstart(it)
        try await service.kickstart(it, killRunning: true)
        try await service.kill(it, signal: 9)
        #expect(runner.calls == [
            ["enable", "gui/501/com.example.agent"],
            ["disable", "gui/501/com.example.agent"],
            ["bootstrap", "gui/501", "/tmp/com.example.agent.plist"],
            ["bootout", "gui/501/com.example.agent"],
            ["kickstart", "gui/501/com.example.agent"],
            ["kickstart", "-k", "gui/501/com.example.agent"],
            ["kill", "9", "gui/501/com.example.agent"],
        ])
        await #expect(throws: LaunchdError.self) { try await service.kill(it, signal: 99) }
    }

    @Test func failedCommandThrowsWithStderr() async {
        let runner = MockRunner()
        runner.responses["bootout gui/501/x.y"] = LaunchctlOutput(status: 3, stdout: "", stderr: "No such process\n")
        let service = LaunchdService(scanner: LaunchdPlistScanner(directories: [], uid: 501), runner: runner, uid: 501)
        await #expect(throws: LaunchdError.commandFailed(status: 3, message: "No such process")) {
            try await service.bootout(self.item("x.y", scope: .userAgent))
        }
    }

    @Test func systemActionsGoThroughHelperAndAppleIsReadOnly() async throws {
        let runner = MockRunner()
        let helper = RecordingPrivileged()
        let service = LaunchdService(scanner: LaunchdPlistScanner(directories: [], uid: 501), runner: runner, privileged: helper, uid: 501)
        let daemon = item("org.example.d", scope: .globalDaemon)
        try await service.disable(daemon)
        try await service.bootstrap(daemon)
        let received = await helper.received
        #expect(received.count == 2)
        #expect(received[0].0 == .disable && received[0].1 == "org.example.d" && received[0].2 == nil)
        #expect(received[1].0 == .bootstrap && received[1].2 == "/tmp/org.example.d.plist")
        #expect(runner.calls.isEmpty)

        await #expect(throws: LaunchdError.readOnlyItem("com.apple.x")) {
            try await service.disable(self.item("com.apple.x", scope: .appleAgent))
        }
    }

    @Test func systemActionWithoutHelperFails() async {
        let service = LaunchdService(scanner: LaunchdPlistScanner(directories: [], uid: 501), runner: MockRunner(), uid: 501)
        await #expect(throws: LaunchdError.helperRequired) {
            try await service.enable(self.item("org.example.d", scope: .globalDaemon))
        }
        #expect(LaunchdError.helperRequired.errorDescription == "Requires the ProcLens helper.")
    }

    @Test func realRunnerRunsAndTimesOut() async throws {
        let echo = ProcessLaunchctlRunner(executable: "/bin/echo")
        let out = try await echo.run(["hello"], timeout: 5)
        #expect(out.status == 0 && out.stdout == "hello\n")
        let sleeper = ProcessLaunchctlRunner(executable: "/bin/sleep")
        await #expect(throws: LaunchdError.timedOut) { _ = try await sleeper.run(["30"], timeout: 0.3) }
        let missing = ProcessLaunchctlRunner(executable: "/nonexistent/launchctl")
        await #expect(throws: LaunchdError.self) { _ = try await missing.run([], timeout: 1) }
    }
}
