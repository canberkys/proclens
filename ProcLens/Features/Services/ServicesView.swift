import SwiftUI
import ProcLensCore

struct ServicesView: View {
    @Environment(AppModel.self) private var model
    @State private var vm = ServicesViewModel()
    @State private var selection: String?
    @State private var pendingStop: LaunchdItemStatus?
    @State private var infoItem: LaunchdItem?

    private enum Col {
        static let pid: CGFloat = 60
        static let status: CGFloat = 130
        static let domain: CGFloat = 80
        static let actions: CGFloat = 28
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Toggle("Running only", isOn: $vm.runningOnly).toggleStyle(.checkbox)
                Toggle("Show Apple services", isOn: $vm.showApple).toggleStyle(.checkbox)
                Spacer()
                if vm.isLoading { ProgressView().controlSize(.small) }
                TextField("Search", text: $vm.search).textFieldStyle(.roundedBorder).frame(width: 200)
                Button { Task { await vm.reload() } } label: { Image(systemName: "arrow.clockwise") }
                    .help("Refresh").accessibilityLabel("Refresh services")
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            Divider()
            HelperBanner(helperEnabled: vm.helperEnabled)
            if let error = vm.error { ErrorBanner(message: error) { vm.error = nil } }
            HStack(spacing: 8) {
                Text("Name").frame(maxWidth: .infinity, alignment: .leading)
                Text("PID").frame(width: Col.pid, alignment: .trailing)
                Text("Status").frame(width: Col.status, alignment: .leading).padding(.leading, 8)
                Text("Domain").frame(width: Col.domain, alignment: .leading)
                Text("Program").frame(maxWidth: .infinity, alignment: .leading)
                Color.clear.frame(width: Col.actions, height: 1)
            }
            .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            .padding(.horizontal, 12).padding(.vertical, 5)
            Divider()
            List(vm.filtered, selection: $selection) { status in row(status).tag(status.id) }
                .listStyle(.inset)
                .overlay {
                    if vm.filtered.isEmpty && !vm.isLoading {
                        ContentUnavailableView(vm.search.isEmpty ? "No services" : "No matches", systemImage: "gearshape.2")
                    }
                }
        }
        .task {
            vm.bind(model.services)
            await vm.run()
        }
        .confirmationDialog(
            "Stop \(pendingStop?.item.label ?? "service")?",
            isPresented: Binding(get: { pendingStop != nil }, set: { if !$0 { pendingStop = nil } }),
            titleVisibility: .visible
        ) {
            Button("Stop", role: .destructive) {
                if let pending = pendingStop { vm.perform(.stop, pending) }
                pendingStop = nil
            }
            Button("Cancel", role: .cancel) { pendingStop = nil }
        } message: {
            Text(pendingStop?.item.keepAlive == .never
                 ? "Sends SIGTERM to the running job."
                 : "This job restarts itself when it exits, so it will be unloaded from launchd until the next login or boot.")
        }
        .sheet(item: $infoItem) { ServiceInfoSheet(item: $0, vm: vm) }
    }

    private func row(_ status: LaunchdItemStatus) -> some View {
        let item = status.item
        let state = ServicesViewModel.statusText(status)
        return HStack(spacing: 8) {
            HStack(spacing: 4) {
                Text(LaunchdPresentation.displayName(for: item)).lineLimit(1).help(item.label)
                if item.domain.isSystem { LockBadge(item: item) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Text(status.pid.map(String.init) ?? "—").monospacedDigit().foregroundStyle(.secondary)
                .frame(width: Col.pid, alignment: .trailing)
            StatusPill(text: state.text, color: state.running ? .green : (state.text.hasPrefix("Exited") ? .orange : .gray))
                .frame(width: Col.status, alignment: .leading).padding(.leading, 8)
            Text(item.domain.isSystem ? "System" : "User").foregroundStyle(.secondary)
                .frame(width: Col.domain, alignment: .leading)
            Text(item.isInterpreterLaunch ? item.effectiveProgram : (item.program.isEmpty ? (item.bundleProgram ?? "—") : item.program))
                .font(.caption).foregroundStyle(.secondary)
                .lineLimit(1).truncationMode(.middle).help(item.program)
                .frame(maxWidth: .infinity, alignment: .leading)
            Menu { actions(status) } label: { Image(systemName: "ellipsis.circle") }
                .menuStyle(.borderlessButton).menuIndicator(.hidden)
                .frame(width: Col.actions)
                .accessibilityLabel("Actions for \(item.label)")
        }
        .padding(.vertical, 2)
        .contextMenu { actions(status) }
    }

    @ViewBuilder
    private func actions(_ status: LaunchdItemStatus) -> some View {
        let item = status.item
        if item.isEditable {
            Button("Start") { vm.perform(.start, status) }.disabled(status.isRunning)
            Button("Restart") { vm.perform(.restart, status) }
            Button("Stop…") { pendingStop = status }.disabled(!status.isRunning)
        } else {
            Text("Part of macOS: read-only")
        }
        Divider()
        Button("Info") { infoItem = item }
        Button("Reveal plist in Finder") { LaunchdPresentation.reveal(item.plistPath) }
        Button("Copy label") { LaunchdPresentation.copy(item.label) }
    }
}

private struct ServiceInfoSheet: View {
    let item: LaunchdItem
    let vm: ServicesViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var result: Result<LaunchctlServiceInfo?, any Error>?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(item.label).font(.headline).textSelection(.enabled)
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            ScrollView {
                Grid(alignment: .topLeading, horizontalSpacing: 12, verticalSpacing: 6) {
                    ForEach(rows, id: \.0) { row in
                        GridRow {
                            Text(row.0).foregroundStyle(.secondary)
                            Text(row.1).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(16)
        .frame(width: 560, height: 440)
        .task { result = await vm.info(for: item) }
    }

    private var rows: [(String, String)] {
        var out: [(String, String)] = [
            ("Plist", item.plistPath),
            ("Domain", item.domain.specifier),
            ("Triggers", item.triggerSummary),
        ]
        switch result {
        case nil: out.append(("State", "Loading…"))
        case .failure(let error):
            let message = item.domain.isSystem ? "\(error.localizedDescription) (system-domain details may need the helper)" : error.localizedDescription
            out.append(("launchctl", message))
        case .success(nil): out.append(("launchctl", "Not loaded, no details available."))
        case .success(let info?):
            out.append(("Target", info.target))
            if let t = info.type { out.append(("Type", t)) }
            if let s = info.state { out.append(("State", String(describing: s))) }
            if let pid = info.pid { out.append(("PID", String(pid))) }
            out.append(("Last exit", info.neverExited ? "Never exited" : info.lastExitCode.map(String.init) ?? "—"))
            if let r = info.runs { out.append(("Runs", String(r))) }
            if let p = info.program { out.append(("Program", p)) }
            if !info.arguments.isEmpty { out.append(("Arguments", info.arguments.joined(separator: " "))) }
            if let b = info.bundleID { out.append(("Bundle ID", b)) }
            if let r = info.immediateReason { out.append(("Immediate reason", r)) }
        }
        return out
    }
}
