import AppKit
import ProcLensCore
import SwiftUI

/// Single place where process actions are validated, confirmed and executed.
/// Tables, the Details tab, the menu bar panel and "End process by PID" all go through it.
@Observable @MainActor
final class ProcessActionCenter {
    struct Pending: Identifiable {
        let id = UUID()
        let action: ProcessAction
        let targets: [ProcessSample]
        /// Processes dropped by `ProtectionPolicy`, with the reason.
        let refused: [(name: String, reason: String)]
    }

    /// Set when an action waits for confirmation.
    var pending: Pending?
    /// Shown as an alert after a refused or failed action.
    var message: String?

    @ObservationIgnored private let model: AppModel

    init(model: AppModel) {
        self.model = model
    }

    /// Entry point for every UI surface. Destructive actions are confirmed first.
    func request(_ action: ProcessAction, on ids: [ProcessID]) {
        let table = model.latest?.processes?.processes ?? [:]
        let targets = ids.compactMap { id in
            table[id] ?? model.liveProcess(pid: id.pid).flatMap { $0.id == id || id.startTime == 0 ? $0 : nil }
        }
        guard !targets.isEmpty else {
            message = "The process is no longer running."
            return
        }
        switch action {
        case .copyPID:
            copy(targets.map { String($0.pid) }.joined(separator: "\n"))
        case .copyPath:
            copy(targets.compactMap(\.path).joined(separator: "\n"))
        case .revealInFinder:
            let urls = targets.compactMap(\.path).map { URL(fileURLWithPath: $0) }
            if !urls.isEmpty { NSWorkspace.shared.activateFileViewerSelecting(urls) }
        case .resume:
            execute(.resume, on: targets)
        case .quit, .forceQuit, .suspend:
            var allowed: [ProcessSample] = []
            var refused: [(String, String)] = []
            for p in targets {
                if case .refused(let reason) = model.protection.verdict(for: p) {
                    refused.append((p.name, reason))
                } else {
                    allowed.append(p)
                }
            }
            if allowed.isEmpty {
                message = refused.map(\.1).joined(separator: "\n")
            } else {
                pending = Pending(action: action, targets: allowed, refused: refused)
            }
        }
    }

    /// "End process by PID" (⌘K) and PID search: resolves the live identity first.
    func requestEnd(pid: pid_t, force: Bool = false) {
        guard let p = model.latest?.processes?.processes.values.first(where: { $0.pid == pid })
                ?? model.liveProcess(pid: pid) else {
            message = "No process with PID \(pid)."
            return
        }
        request(force ? .forceQuit : .quit, on: [p.id])
    }

    func confirm() {
        guard let pending else { return }
        self.pending = nil
        execute(pending.action, on: pending.targets)
    }

    func cancel() {
        pending = nil
    }

    // MARK: - Private

    private func execute(_ action: ProcessAction, on targets: [ProcessSample]) {
        var failures: [String] = []
        for p in targets {
            // The pid may have been reused since the request: only act on the same process.
            guard model.isAlive(p.id) else { continue }
            if let error = send(action, to: p) { failures.append("\(p.name) (\(p.pid)): \(error)") }
        }
        if !failures.isEmpty { message = failures.joined(separator: "\n") }
    }

    /// Returns an error description, or nil on success.
    private func send(_ action: ProcessAction, to p: ProcessSample) -> String? {
        let app = NSRunningApplication(processIdentifier: p.pid)
        switch action {
        case .quit:
            if let app, app.activationPolicy == .regular { return app.terminate() ? nil : "The app refused to quit." }
            return signal(SIGTERM, p.pid)
        case .forceQuit:
            if let app { return app.forceTerminate() ? nil : signal(SIGKILL, p.pid) }
            return signal(SIGKILL, p.pid)
        case .suspend:
            return signal(SIGSTOP, p.pid)
        case .resume:
            return signal(SIGCONT, p.pid)
        case .revealInFinder, .copyPath, .copyPID:
            return nil
        }
    }

    private func signal(_ sig: Int32, _ pid: pid_t) -> String? {
        guard kill(pid, sig) != 0 else { return nil }
        switch errno {
        case EPERM: return "Not permitted. Ending processes of other users needs the helper (Phase 2)."
        case ESRCH: return nil // already gone: the intent is satisfied
        default: return String(cString: strerror(errno))
        }
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

extension ProcessAction {
    /// Text for the confirmation alert, Windows Task Manager style.
    func confirmationTitle(for targets: [ProcessSample]) -> String {
        let subject = targets.count == 1 ? "“\(targets[0].name)” (PID \(targets[0].pid))" : "\(targets.count) processes"
        switch self {
        case .quit: return "End \(subject)?"
        case .forceQuit: return "Force quit \(subject)?"
        case .suspend: return "Suspend \(subject)?"
        default: return title
        }
    }

    var confirmationDetail: String {
        switch self {
        case .quit: "Apps are asked to quit; other processes receive SIGTERM. Unsaved data may be lost."
        case .forceQuit: "The process is killed immediately (SIGKILL). Unsaved data will be lost."
        case .suspend: "The process stops running until it is resumed (SIGSTOP)."
        default: ""
        }
    }
}

private struct ProcessActionConfirmation: ViewModifier {
    @Bindable var center: ProcessActionCenter

    func body(content: Content) -> some View {
        content
            .alert(
                center.pending.map { $0.action.confirmationTitle(for: $0.targets) } ?? "",
                isPresented: Binding(get: { center.pending != nil }, set: { if !$0 { center.cancel() } }),
                presenting: center.pending
            ) { pending in
                Button(pending.action.title, role: .destructive) { center.confirm() }
                Button("Cancel", role: .cancel) { center.cancel() }
            } message: { pending in
                let skipped = pending.refused.map { "Skipped \($0.name): \($0.reason)" }
                Text(([pending.action.confirmationDetail] + skipped).joined(separator: "\n\n"))
            }
            .alert(
                "ProcLens",
                isPresented: Binding(get: { center.message != nil }, set: { if !$0 { center.message = nil } })
            ) {
                Button("OK", role: .cancel) { center.message = nil }
            } message: {
                Text(center.message ?? "")
            }
    }
}

extension View {
    /// Presents confirmation and error alerts for `center`. Apply once per window/panel.
    func processActionConfirmation(_ center: ProcessActionCenter) -> some View {
        modifier(ProcessActionConfirmation(center: center))
    }
}
