import Darwin
import ProcLensCore
import SwiftUI

/// About ProcLens, with a live "self-overhead" line read from the latest snapshot (no extra sampling).
struct AboutView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    private var version: String {
        let info = Bundle.main.infoDictionary
        let v = info?["CFBundleShortVersionString"] as? String ?? "?"
        let b = info?["CFBundleVersion"] as? String ?? "?"
        return "Version \(v) (\(b))"
    }

    private var overhead: String {
        guard let table = model.latest?.processes else { return "Self-overhead: waiting for the first sample" }
        let me = getpid()
        guard let p = table.processes.values.first(where: { $0.pid == me }) else {
            return "Self-overhead: ProcLens is not in the process table"
        }
        return "Self-overhead: CPU \(Format.cpuPercent(p.cpu)) · Memory \(Format.bytes(p.memory))"
    }

    private var sampling: String {
        let n = model.latest?.processes?.processes.count ?? 0
        return "Sampling every \(model.interval.rawValue.formatted()) s · \(n) processes"
    }

    var body: some View {
        VStack(spacing: 8) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable().frame(width: 72, height: 72)
                .accessibilityHidden(true)
            Text("ProcLens").font(.title2.bold())
            Text(version).foregroundStyle(.secondary)
            Text("A native Task Manager for macOS.").font(.callout)
            Divider().padding(.vertical, 6)
            VStack(spacing: 4) {
                Text(overhead).monospacedDigit()
                Text(sampling).foregroundStyle(.secondary)
            }
            .font(.callout)
            .accessibilityElement(children: .combine)
            Button("OK") { dismiss() }
                .keyboardShortcut(.defaultAction)
                .padding(.top, 10)
        }
        .padding(24)
        .frame(width: 340)
    }
}
