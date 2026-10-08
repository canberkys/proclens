import AppKit
import ProcLensCore
import ProcLensHelperProtocol
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

    /// "End process tree" waiting for confirmation (root + descendants, children first).
    struct PendingTree: Identifiable {
        let id = UUID()
        let root: ProcessSample
        let table: ProcessTable
        let descendantCount: Int
    }

    /// Set when an action waits for confirmation.
    var pending: Pending?
    var pendingTree: PendingTree?
    /// Shown as an alert after a refused or failed action.
    var message: String?

    @ObservationIgnored private let model: AppModel
    @ObservationIgnored private let treeKiller = TreeKiller(privileged: HelperClient.shared)

    init(model: AppModel) {
        self.model = model
        #if DEBUG
        DispatchQueue.main.async { [self] in DetailsDebug.scheduleIfRequested(model: model, actions: self) }
        #endif
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
            Task { await execute(.resume, on: targets) }
        case .properties:
            for p in targets.prefix(8) { InspectorWindows.shared.show(p, model: model, actions: self) }
        case .endTree:
            if let first = targets.first { requestEndTree(first.id) }
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

    /// Ends `id` and all its descendants (children first). Protected roots are refused here; protected
    /// descendants are skipped by `TreeKiller`. Always confirmed first.
    func requestEndTree(_ id: ProcessID) {
        guard let table = model.latest?.processes ?? model.services.lastProcessTable,
              let root = table.processes[id] else {
            message = "The process is no longer running."
            return
        }
        if case .refused(let reason) = model.protection.verdict(for: root) {
            message = reason
            return
        }
        let count = ProcessTree(table: table).descendants(of: id).count
        pendingTree = PendingTree(root: root, table: table, descendantCount: count)
    }

    func confirmTree() {
        guard let tree = pendingTree else { return }
        pendingTree = nil
        Task { [treeKiller] in
            let results = await treeKiller.kill(root: tree.root.id, in: tree.table)
            let failures = results.compactMap { r -> String? in
                switch r.outcome {
                case .refused(let reason): return r.id == tree.root.id ? "\(r.name): \(reason)" : nil
                case .failed(let e): return "\(r.name) (\(r.id.pid)): \(String(cString: strerror(e)))"
                default: return nil
                }
            }
            if !failures.isEmpty { message = failures.joined(separator: "\n") }
        }
    }

    func cancelTree() {
        pendingTree = nil
    }

    func confirm() {
        guard let pending else { return }
        self.pending = nil
        Task { [action = pending.action, targets = pending.targets] in await execute(action, on: targets) }
    }

    func cancel() {
        pending = nil
    }

    // MARK: - Private

    private func execute(_ action: ProcessAction, on targets: [ProcessSample]) async {
        var failures: [String] = []
        for p in targets {
            // The pid may have been reused since the request: only act on the same process.
            guard model.isAlive(p.id) else { continue }
            if let error = await send(action, to: p) { failures.append("\(p.name) (\(p.pid)): \(error)") }
        }
        if !failures.isEmpty { message = failures.joined(separator: "\n") }
    }

    /// Returns an error description, or nil on success.
    private func send(_ action: ProcessAction, to p: ProcessSample) async -> String? {
        let app = NSRunningApplication(processIdentifier: p.pid)
        switch action {
        case .quit:
            if let app, app.activationPolicy == .regular { return app.terminate() ? nil : "The app refused to quit." }
            return await signal(SIGTERM, p)
        case .forceQuit:
            if let app { if app.forceTerminate() { return nil }; return await signal(SIGKILL, p) }
            return await signal(SIGKILL, p)
        case .suspend:
            return await signal(SIGSTOP, p)
        case .resume:
            return await signal(SIGCONT, p)
        case .revealInFinder, .copyPath, .copyPID, .properties, .endTree:
            return nil
        }
    }

    /// `kill(2)`; on EPERM, retried through the privileged helper when it is enabled (it still refuses critical
    /// processes and checks the start time against pid reuse).
    private func signal(_ sig: Int32, _ p: ProcessSample) async -> String? {
        guard kill(p.pid, sig) != 0 else { return nil }
        let err = errno
        switch err {
        case EPERM:
            guard model.services.helper.isEnabled else {
                return "Not permitted. Ending processes of other users needs the helper (Phase 2)."
            }
            do {
                try await model.services.helper.signalProcess(pid: p.pid, signal: sig, expectedStartTime: p.id.startTime, expectedName: p.name)
                return nil
            } catch let failure as HelperFailure where failure.code == .notFound || failure.code == .processChanged {
                return nil // already gone (or replaced): the intent is satisfied
            } catch {
                return error.localizedDescription
            }
        case ESRCH: return nil // already gone: the intent is satisfied
        default: return String(cString: strerror(err))
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
                center.pendingTree.map { "End process tree of “\($0.root.name)” (PID \($0.root.pid))?" } ?? "",
                isPresented: Binding(get: { center.pendingTree != nil }, set: { if !$0 { center.cancelTree() } }),
                presenting: center.pendingTree
            ) { _ in
                Button("End process tree", role: .destructive) { center.confirmTree() }
                Button("Cancel", role: .cancel) { center.cancelTree() }
            } message: { tree in
                Text("\(tree.descendantCount) child process\(tree.descendantCount == 1 ? "" : "es") will be ended first, then “\(tree.root.name)”. Processes get SIGTERM, survivors SIGKILL after 3 seconds. Unsaved data will be lost.")
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
