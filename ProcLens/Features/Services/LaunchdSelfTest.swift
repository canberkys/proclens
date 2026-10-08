#if DEBUG
import Foundation
import AppKit
import ProcLensCore

/// `-ProcLensSelfTest <logpath>`: drives LaunchdService against ~/Library/LaunchAgents/com.proclens.selftest.plist
/// (user domain only), logs each step to <logpath>, then quits.
@MainActor enum LaunchdSelfTest {
    private static var started = false
    static let label = "com.proclens.selftest"

    @MainActor
    static func runIfRequested(services: AppServices) async {
        guard let log = UserDefaults.standard.string(forKey: "ProcLensSelfTest"), !started else { return }
        started = true
        var lines: [String] = []
        func note(_ s: String) { lines.append(s) }
        func state() async -> LaunchdItemStatus? { await services.launchd.items().first { $0.item.label == label } }
        func sleepRunning(_ pid: Int?) -> Bool { pid.map { kill(pid_t($0), 0) == 0 } ?? false }

        guard var s = await state() else { note("FAIL: plist not found"); finish(lines, log); return }
        let launchd = services.launchd
        do {
            note("start: loaded=\(s.isLoaded) enabled=\(s.isEnabled)")
            try await launchd.bootstrap(s.item)
            s = await state() ?? s
            note("bootstrap: loaded=\(s.isLoaded) pid=\(String(describing: s.pid)) \(s.isLoaded && s.pid == nil ? "PASS" : "FAIL")")
            try await launchd.kickstart(s.item)
            try? await Task.sleep(for: .milliseconds(600))
            s = await state() ?? s
            note("kickstart: pid=\(String(describing: s.pid)) alive=\(sleepRunning(s.pid)) \(sleepRunning(s.pid) ? "PASS" : "FAIL")")
            let pid = s.pid
            try await launchd.kill(s.item, signal: SIGTERM)
            try? await Task.sleep(for: .milliseconds(600))
            s = await state() ?? s
            note("kill: pid=\(String(describing: s.pid)) oldAlive=\(sleepRunning(pid)) \(!sleepRunning(pid) ? "PASS" : "FAIL")")
            try await launchd.bootout(s.item)
            s = await state() ?? s
            note("bootout: loaded=\(s.isLoaded) \(!s.isLoaded ? "PASS" : "FAIL")")
            try await launchd.disable(s.item)
            s = await state() ?? s
            note("disable: enabled=\(s.isEnabled) \(!s.isEnabled ? "PASS" : "FAIL")")
            try await launchd.enable(s.item)
            s = await state() ?? s
            note("enable: enabled=\(s.isEnabled) \(s.isEnabled ? "PASS" : "FAIL")")
            // System-domain without helper must fail clearly.
            if services.helper.registrationStatus() != .enabled {
                do {
                    try LaunchdPresentation.preflight(LaunchdItem.systemProbe, helper: services.helper)
                    note("helper-missing preflight: FAIL (no error)")
                } catch { note("helper-missing preflight: PASS (\(error.localizedDescription))") }
            }
        } catch {
            note("ERROR: \(error.localizedDescription)")
        }
        finish(lines, log)
    }

    @MainActor private static func finish(_ lines: [String], _ path: String) {
        try? lines.joined(separator: "\n").appending("\n").write(toFile: path, atomically: true, encoding: .utf8)
        NSApp.terminate(nil)
    }
}

private extension LaunchdItem {
    static var systemProbe: LaunchdItem {
        let data = Data("<?xml version=\"1.0\"?><plist version=\"1.0\"><dict><key>Label</key><string>com.example.probe</string><key>ProgramArguments</key><array><string>/bin/true</string></array></dict></plist>".utf8)
        if case .success(let item) = LaunchdPlistScanner.parse(data: data, path: "/Library/LaunchDaemons/com.example.probe.plist", scope: .globalDaemon, uid: getuid()) { return item }
        fatalError("probe plist")
    }
}
#endif
