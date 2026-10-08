import Darwin
import Foundation
import ProcLensCore
import ProcLensHelperProtocol

/// `-ProcLensHelperProbe`: prints what the privileged helper contributes (merged samples of root processes,
/// helper-supplied ports, the signal path) to stdout, then exits. Read-only; the only signal it sends is SIGCONT
/// (a no-op for running processes), and critical processes are expected to be refused. Meant for verifying a
/// signed build against the installed helper; run with `PROCLENS_FORCE_VISIBLE=1`.
@MainActor
enum HelperProbe {
    static func runIfRequested(model: AppModel) {
        guard CommandLine.arguments.contains("-ProcLensHelperProbe") else { return }
        Task { @MainActor in
            await run(model: model)
            exit(0)
        }
    }

    private static func say(_ text: String) {
        print("[helper-probe] \(text)")
        fflush(stdout)
    }

    private static func run(model: AppModel) async {
        let helper = model.services.helper
        say("registration: \(helper.registrationStatus(forceRefresh: true))")
        if let info = try? await helper.helperVersion() {
            say("helper protocol \(info.protocolVersion) build \(info.build)")
        } else {
            say("helper version: unreachable")
        }

        // Ticks are 1 s: let the helper batch land a few times so rates exist.
        var table: ProcessTable?
        for _ in 0..<12 {
            try? await Task.sleep(for: .seconds(1))
            table = model.latest?.processes
        }
        guard let table else { say("no process table (window hidden? set PROCLENS_FORCE_VISIBLE=1)"); return }
        let restricted = table.processes.values.filter(\.isRestricted).count
        let viaHelper = table.processes.values.filter(\.viaHelper).count
        say("processes \(table.processes.count), still restricted \(restricted), via helper \(viaHelper)")
        for name in ["mds", "logd", "mDNSResponder", "launchd", "powerd"] {
            guard let p = table.processes.values.first(where: { $0.name == name && $0.uid == 0 }) else { continue }
            let values = String(format: "cpu=%.2f%% mem=%.1fMB threads=%d energy=%.1f diskR=%.0fB/s diskW=%.0fB/s",
                                p.cpu * 100, Double(p.memory) / 1_048_576, p.threadCount, p.energy,
                                p.diskReadPerSec, p.diskWritePerSec)
            say("\(name) pid \(p.pid) restricted=\(p.isRestricted) viaHelper=\(p.viaHelper) \(values)")
        }

        let ports = await model.services.scanPorts()
        let viaRoot = ports.filter { table.processes[$0.processID]?.viaHelper == true }
        say("listening ports \(ports.count), of helper-backed processes \(viaRoot.count)")
        for port in viaRoot.prefix(8) {
            say("  \(port.proto.rawValue) \(port.address):\(port.port) pid \(port.pid) \(table.processes[port.processID]?.name ?? "?")")
        }

        // Signal path (SIGCONT is a no-op on running processes): critical process refused, wrong start time refused.
        if let mds = table.processes.values.first(where: { $0.name == "mds" && $0.uid == 0 }) {
            do {
                try await helper.signalProcess(pid: mds.pid, signal: SIGCONT, expectedStartTime: mds.id.startTime, expectedName: mds.name)
                say("signal mds: UNEXPECTEDLY allowed")
            } catch {
                say("signal mds (critical): refused as expected: \(error.localizedDescription)")
            }
        }
        if let target = table.processes.values.first(where: { $0.name == "fseventsd" && $0.uid == 0 }) {
            do {
                try await helper.signalProcess(pid: target.pid, signal: SIGCONT, expectedStartTime: target.id.startTime, expectedName: "not-" + target.name)
                say("signal with another process name: UNEXPECTEDLY allowed")
            } catch {
                say("signal with another process name: refused as expected: \(error.localizedDescription)")
            }
            do {
                try await helper.signalProcess(pid: target.pid, signal: SIGCONT, expectedStartTime: target.id.startTime, expectedName: target.name)
                say("signal SIGCONT fseventsd, matching identity: ok (no-op on a running process)")
            } catch {
                say("signal SIGCONT, matching identity: failed: \(error.localizedDescription)")
            }
        }
    }
}
