import SwiftUI
import ProcLensCore

/// Windows-style "Startup apps": launchd agents/daemons that start automatically, grouped by vendor.
struct StartupView: View {
    @Environment(AppModel.self) private var model
    @State private var vm = StartupViewModel()
    @State private var pendingDisable: LaunchdItemStatus?
    @State private var plistToShow: String?
    @State private var showInvalid = false

    private enum Col {
        static let type: CGFloat = 90
        static let status: CGFloat = 84
        static let signed: CGFloat = 150
        static let actions: CGFloat = 28
    }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            HelperBanner(helperEnabled: vm.helperEnabled)
            if let error = vm.error { ErrorBanner(message: error) { vm.error = nil } }
            header
            Divider()
            list
        }
        .task {
            vm.bind(model.services)
            await vm.run()
        }
        .confirmationDialog(
            "Disable \(pendingDisable.map { LaunchdPresentation.displayName(for: $0.item) } ?? "item")?",
            isPresented: Binding(get: { pendingDisable != nil }, set: { if !$0 { pendingDisable = nil } }),
            titleVisibility: .visible
        ) {
            Button("Disable", role: .destructive) {
                if let pending = pendingDisable { vm.setEnabled(false, pending) }
                pendingDisable = nil
            }
            Button("Cancel", role: .cancel) { pendingDisable = nil }
        } message: {
            Text("It will not start automatically at login or boot. A job that is already running keeps running until it exits.")
        }
        .sheet(isPresented: Binding(get: { plistToShow != nil }, set: { if !$0 { plistToShow = nil } })) {
            if let plistToShow { PlistViewerSheet(path: plistToShow) }
        }
    }

    // MARK: - Chrome

    private var toolbar: some View {
        HStack(spacing: 10) {
            Picker("Filter", selection: $vm.filter) {
                ForEach(StartupFilter.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented).labelsHidden().frame(width: 260)
            Toggle("Show Apple items", isOn: $vm.showApple)
                .toggleStyle(.checkbox)
                .disabled(vm.filter == .apple)
            Spacer()
            if vm.isLoading { ProgressView().controlSize(.small) }
            TextField("Search", text: $vm.search)
                .textFieldStyle(.roundedBorder).frame(width: 200)
            Button { Task { await vm.reload() } } label: { Image(systemName: "arrow.clockwise") }
                .help("Refresh").accessibilityLabel("Refresh startup items")
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text("Name").frame(maxWidth: .infinity, alignment: .leading).padding(.leading, 28)
            Text("Type").frame(width: Col.type, alignment: .leading)
            Text("Status").frame(width: Col.status, alignment: .leading)
            Text("Signed by").frame(width: Col.signed, alignment: .leading)
            Text("Location").frame(maxWidth: .infinity, alignment: .leading)
            Color.clear.frame(width: Col.actions, height: 1)
        }
        .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
        .padding(.horizontal, 12).padding(.vertical, 5)
    }

    private var list: some View {
        List {
            ForEach(vm.groups) { group in
                Section(group.vendor) {
                    ForEach(group.items) { status in row(status) }
                }
            }
            if !vm.visibleLoginItems.isEmpty {
                Section("Login items") {
                    ForEach(vm.visibleLoginItems) { loginRow($0) }
                }
            }
            if !vm.invalid.isEmpty {
                Section {
                    DisclosureGroup("Invalid items (\(vm.invalid.count))", isExpanded: $showInvalid) {
                        ForEach(vm.invalid) { bad in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(bad.path).font(.callout).textSelection(.enabled).lineLimit(1).truncationMode(.middle)
                                Text(bad.reason).font(.caption).foregroundStyle(.red)
                            }
                            .contextMenu {
                                Button("Reveal in Finder") { LaunchdPresentation.reveal(bad.path) }
                                Button("Open plist") { plistToShow = bad.path }
                            }
                        }
                    }
                }
            }
        }
        .listStyle(.inset)
        .overlay {
            if vm.groups.isEmpty && vm.visibleLoginItems.isEmpty && !vm.isLoading {
                ContentUnavailableView(vm.search.isEmpty ? "No startup items" : "No matches", systemImage: "power",
                                       description: Text(vm.filter == .all && !vm.showApple ? "Apple items are hidden. Turn on Show Apple items to list them." : "Nothing to show for this filter."))
            }
        }
    }

    // MARK: - Rows

    private func row(_ status: LaunchdItemStatus) -> some View {
        let item = status.item
        let sign = vm.signingStatus(for: item)
        return HStack(spacing: 8) {
            Image(nsImage: LaunchdIconCache.icon(for: item)).resizable().frame(width: 20, height: 20)
            HStack(spacing: 4) {
                Text(LaunchdPresentation.displayName(for: item)).lineLimit(1)
                if item.domain.isSystem { LockBadge(item: item) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Text(LaunchdPresentation.typeLabel(item.scope)).foregroundStyle(.secondary)
                .frame(width: Col.type, alignment: .leading)
            StatusPill(text: status.isEnabled ? "Enabled" : "Disabled", color: status.isEnabled ? .green : .gray)
                .frame(width: Col.status, alignment: .leading)
            Text(sign?.label ?? "…").foregroundStyle(.secondary).lineLimit(1)
                .frame(width: Col.signed, alignment: .leading)
            Text(item.plistPath).font(.caption).foregroundStyle(.secondary)
                .lineLimit(1).truncationMode(.middle)
                .help(item.plistPath)
                .frame(maxWidth: .infinity, alignment: .leading)
            Menu { actions(status) } label: { Image(systemName: "ellipsis.circle") }
                .menuStyle(.borderlessButton).menuIndicator(.hidden)
                .frame(width: Col.actions)
                .accessibilityLabel("Actions for \(item.label)")
        }
        .padding(.vertical, 2)
        .onAppear { vm.loadSigning(for: item) }
        .contextMenu { actions(status) }
    }

    @ViewBuilder
    private func actions(_ status: LaunchdItemStatus) -> some View {
        let item = status.item
        if item.isEditable {
            if status.isEnabled {
                Button("Disable…") { pendingDisable = status }
            } else {
                Button("Enable") { vm.setEnabled(true, status) }
            }
            Divider()
        } else {
            Text("Part of macOS: read-only")
            Divider()
        }
        Button("Reveal plist in Finder") { LaunchdPresentation.reveal(item.plistPath) }
        Button("Open plist") { plistToShow = item.plistPath }
        Button("Copy label") { LaunchdPresentation.copy(item.label) }
    }

    private func loginRow(_ item: BackgroundItem) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "person.crop.circle").frame(width: 20)
            Text(item.name).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
            Text("Login item").foregroundStyle(.secondary).frame(width: Col.type, alignment: .leading)
            StatusPill(text: item.isEnabled ? "Enabled" : "Disabled", color: item.isEnabled ? .green : .gray)
                .frame(width: Col.status, alignment: .leading)
            Text(item.developerName ?? "—").foregroundStyle(.secondary).lineLimit(1)
                .frame(width: Col.signed, alignment: .leading)
            Text(item.url ?? item.executablePath ?? "").font(.caption).foregroundStyle(.secondary)
                .lineLimit(1).truncationMode(.middle).frame(maxWidth: .infinity, alignment: .leading)
            Color.clear.frame(width: Col.actions, height: 1)
        }
        .help("Manage in System Settings > General > Login Items")
    }
}
