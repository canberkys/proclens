import Darwin
import ProcLensCore
import SwiftUI

/// "End process by PID" (⌘K): numeric field, live preview of the match, End task / Force quit.
struct EndByPIDSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(ProcessActionCenter.self) private var actions
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @FocusState private var focused: Bool

    private var pid: pid_t? { Int32(text.trimmingCharacters(in: .whitespaces)) }

    private var match: ProcessSample? {
        guard let pid else { return nil }
        return model.latest?.processes?.processes.values.first { $0.pid == pid }
    }

    private var preview: String {
        guard let pid else { return text.isEmpty ? "Enter a process ID" : "Not a valid PID" }
        guard let p = match else { return "No such process" }
        return "PID \(pid) — \(p.name) (\(Self.userName(p.uid)))"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("End process by PID").font(.headline)
            TextField("PID", text: $text)
                .textFieldStyle(.roundedBorder)
                .focused($focused)
                .onSubmit { end(force: false) }
                .accessibilityLabel("Process ID")
            Text(preview)
                .foregroundStyle(match == nil ? .secondary : .primary)
                .lineLimit(2)
                .accessibilityLabel("Match: \(preview)")
            HStack {
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Force quit", role: .destructive) { end(force: true) }
                    .disabled(match == nil)
                Button("End task") { end(force: false) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(match == nil)
            }
        }
        .padding(20)
        .frame(width: 380)
        .onAppear { focused = true }
    }

    private func end(force: Bool) {
        guard let pid, match != nil else { return }
        dismiss()
        actions.requestEnd(pid: pid, force: force)
    }

    static func userName(_ uid: uid_t) -> String {
        #if DEBUG
        if DemoMode.isActive { return DemoMode.userName(uid) }
        #endif
        var pwd = passwd()
        var result: UnsafeMutablePointer<passwd>?
        var buffer = [CChar](repeating: 0, count: 1024)
        if getpwuid_r(uid, &pwd, &buffer, buffer.count, &result) == 0, result != nil {
            return String(cString: pwd.pw_name)
        }
        return String(uid)
    }
}
