import AppKit
import ProcLensCore
import SwiftUI

struct InspectorView: View {
    enum Tab: Int, CaseIterable, Identifiable {
        case general, environment, files, images, signing
        var id: Int { rawValue }
        var title: String {
            switch self {
            case .general: "General"
            case .environment: "Environment"
            case .files: "Files & Sockets"
            case .images: "Loaded Images"
            case .signing: "Signing"
            }
        }
    }

    let model: InspectorModel
    @State private var tab: Tab = {
        #if DEBUG
        if let t = Tab(rawValue: UserDefaults.standard.integer(forKey: "ProcLensInspectTab")) { return t }
        #endif
        return .general
    }()

    var body: some View {
        VStack(spacing: 0) {
            InspectorHeader(model: model)
            if model.isRestricted {
                Label("This process belongs to another user or is protected. Some details need the ProcLens helper.",
                      systemImage: "lock.shield")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 8)
            }
            Picker("Section", selection: $tab) {
                ForEach(Tab.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 16)
            .padding(.bottom, 10)
            Divider()
            Group {
                switch tab {
                case .general: GeneralTab(model: model)
                case .environment: EnvironmentTab(model: model)
                case .files: FilesTab(model: model)
                case .images: ImagesTab(model: model)
                case .signing: SigningTab(model: model)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

// MARK: - Header

/// The only live part of the inspector: CPU and memory text, updated from the visible snapshot (one dictionary
/// lookup per tick, two strings). Everything else is fetched on open / Refresh.
private struct InspectorHeader: View {
    let model: InspectorModel
    @State private var cpu = "—"
    @State private var memory = "—"
    @State private var exited = false

    var body: some View {
        HStack(spacing: 12) {
            Image(nsImage: model.app.icon(for: model.id.pid) ?? NSWorkspace.shared.icon(for: .unixExecutable))
                .resizable().frame(width: 32, height: 32)
            VStack(alignment: .leading, spacing: 2) {
                Text(model.sample.name).font(.title3.weight(.semibold)).lineLimit(1)
                Text(verbatim: exited ? "PID \(model.id.pid) · exited" : "PID \(model.id.pid) · CPU \(cpu) · Memory \(memory)")
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if let updated = model.updated {
                Text("Updated \(updated.formatted(date: .omitted, time: .standard))")
                    .font(.caption).foregroundStyle(.tertiary)
            }
            Button { model.refresh() } label: { Label("Refresh", systemImage: "arrow.clockwise") }
                .keyboardShortcut("r", modifiers: .command)
                .help("Read everything again (⌘R)")
        }
        .padding(16)
        .onChange(of: model.app.visibleSnapshot?.instant, initial: true) { update() }
    }

    private func update() {
        guard let snap = model.app.visibleSnapshot, let table = snap.processes else { return }
        guard let p = table.processes[model.id] else { exited = true; return }
        exited = false
        if p.isRestricted { cpu = "—"; memory = "—"; return }
        let cores = Double(max(1, snap.cpu?.cores.count ?? 1))
        cpu = FastFormat.percent(p.cpu / cores)
        memory = FastFormat.bytes(p.memory)
    }
}

// MARK: - Shared pieces

private struct HelperNote: View {
    let text: String
    let needsHelper: Bool

    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: needsHelper ? "lock.shield" : "exclamationmark.circle")
                .font(.title).foregroundStyle(.secondary)
            if needsHelper { Text("Needs the ProcLens helper").font(.headline) }
            Text(text).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct Spinner: View {
    var body: some View {
        ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private func copy(_ text: String) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(text, forType: .string)
}

private struct SearchBar: View {
    @Binding var text: String
    let prompt: String
    var trailing: AnyView?

    var body: some View {
        HStack {
            TextField(prompt, text: $text).textFieldStyle(.roundedBorder)
            trailing
        }
        .padding(.horizontal, 16).padding(.vertical, 8)
    }
}

// MARK: - General

private struct GeneralTab: View {
    let model: InspectorModel

    var body: some View {
        let p = model.sample
        ScrollView {
            Grid(alignment: .topLeading, horizontalSpacing: 16, verticalSpacing: 8) {
                row("Name", p.name)
                row("PID", String(p.pid))
                row("Parent", model.parentName.map { "\($0) (\(p.ppid))" } ?? String(p.ppid))
                row("User", "\(model.userName) (\(p.uid))")
                row("Architecture", model.archText)
                row("Path", p.path ?? "—")
                row("Started", model.startText)
                row("Threads", p.isRestricted ? "—" : String(p.threadCount))
                GridRow {
                    label("Command line")
                    switch model.args {
                    case .loading: ProgressView().controlSize(.small)
                    case .loaded: Text(model.commandLine ?? "—").textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                    case .failed(let msg, let helper):
                        Text(helper ? "Needs the ProcLens helper. \(msg)" : msg).foregroundStyle(.secondary)
                    }
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func label(_ s: String) -> some View {
        Text(s).foregroundStyle(.secondary).gridColumnAlignment(.trailing)
    }

    private func row(_ title: String, _ value: String) -> some View {
        GridRow {
            label(title)
            Text(value).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - Environment

private struct EnvironmentTab: View {
    let model: InspectorModel
    @State private var query = ""
    @State private var selection = Set<String>()

    var body: some View {
        switch model.args {
        case .loading: Spinner()
        case .failed(let msg, let helper): HelperNote(text: msg, needsHelper: helper)
        case .loaded:
            let all = model.environment
            let q = query.lowercased()
            let rows = q.isEmpty ? all : all.filter { $0.key.lowercased().contains(q) || $0.value.lowercased().contains(q) }
            VStack(spacing: 0) {
                SearchBar(text: $query, prompt: "Search \(all.count) variables", trailing: AnyView(
                    Button("Copy all") { copy(rows.map { "\($0.key)=\($0.value)" }.joined(separator: "\n")) }
                        .disabled(rows.isEmpty)))
                if all.isEmpty {
                    HelperNote(text: "This process has no environment, or it is not readable.", needsHelper: false)
                } else {
                    Table(rows, selection: $selection) {
                        TableColumn("Variable") { Text($0.key).font(.body.monospaced()).lineLimit(1) }.width(min: 120, ideal: 200)
                        TableColumn("Value") { Text($0.value).font(.body.monospaced()).lineLimit(1) }
                    }
                    .contextMenu(forSelectionType: String.self) { keys in
                        Button("Copy") { copyRows(rows.filter { keys.contains($0.key) }) }
                    }
                }
            }
        }
    }

    private func copyRows(_ rows: [InspectorModel.KeyValue]) {
        copy(rows.map { "\($0.key)=\($0.value)" }.joined(separator: "\n"))
    }
}

// MARK: - Files & sockets

private struct FilesTab: View {
    let model: InspectorModel
    @State private var query = ""
    @State private var group: InspectorModel.DescriptorRow.Group = .all
    @State private var selection = Set<Int32>()

    var body: some View {
        switch model.descriptors {
        case .loading: Spinner()
        case .failed(let msg, let helper): HelperNote(text: msg, needsHelper: helper)
        case .loaded:
            let all = model.descriptorRows
            let q = query.lowercased()
            let rows = all.filter { r in
                (group == .all || r.group == group)
                    && (q.isEmpty || r.name.lowercased().contains(q) || r.remote.lowercased().contains(q)
                        || r.type.lowercased().contains(q) || r.state.lowercased().contains(q))
            }
            VStack(spacing: 0) {
                SearchBar(text: $query, prompt: "Search \(all.count) descriptors", trailing: AnyView(
                    Picker("Show", selection: $group) {
                        ForEach(InspectorModel.DescriptorRow.Group.allCases) { Text($0.rawValue).tag($0) }
                    }.pickerStyle(.segmented).labelsHidden().frame(width: 300)))
                Table(rows, selection: $selection) {
                    TableColumn("FD") { Text(String($0.id)).monospacedDigit() }.width(40)
                    TableColumn("Type") { Text($0.type) }.width(80)
                    TableColumn("Name / Local") { Text($0.name).lineLimit(1).truncationMode(.middle) }.width(min: 160, ideal: 300)
                    TableColumn("Remote") { Text($0.remote).lineLimit(1) }.width(min: 80, ideal: 160)
                    TableColumn("State") { Text($0.state) }.width(90)
                    TableColumn("Mode") { Text($0.mode) }.width(44)
                }
                .contextMenu(forSelectionType: Int32.self) { fds in
                    Button("Copy") {
                        copy(rows.filter { fds.contains($0.id) }
                            .map { [String($0.id), $0.type, $0.name, $0.remote, $0.state].filter { !$0.isEmpty }.joined(separator: "\t") }
                            .joined(separator: "\n"))
                    }
                }
            }
        }
    }
}

// MARK: - Loaded images

private struct ImagesTab: View {
    let model: InspectorModel
    @State private var query = ""
    @State private var selection = Set<String>()

    var body: some View {
        switch model.images {
        case .loading: Spinner()
        case .failed(let msg, let helper): HelperNote(text: msg, needsHelper: helper)
        case .loaded(let all):
            let q = query.lowercased()
            let rows = q.isEmpty ? all : all.filter { $0.path.lowercased().contains(q) }
            VStack(spacing: 0) {
                SearchBar(text: $query, prompt: "Search \(all.count) mapped files", trailing: nil)
                Table(rows, selection: $selection) {
                    TableColumn("Path") { Text($0.path).lineLimit(1).truncationMode(.middle) }.width(min: 200, ideal: 420)
                    TableColumn("Size") { Text(Self.size($0.totalSize)).monospacedDigit() }.width(70)
                    TableColumn("Regions") { Text(String($0.regionCount)).monospacedDigit() }.width(56)
                    TableColumn("Base address") { Text("0x" + String($0.baseAddress, radix: 16)).font(.body.monospaced()) }.width(110)
                    TableColumn("Exec") { Text($0.isExecutable ? "Yes" : "") }.width(40)
                }
                .contextMenu(forSelectionType: String.self) { paths in
                    Button("Copy path") { copy(paths.sorted().joined(separator: "\n")) }
                }
                Text("Files mapped into the process. System libraries from the dyld shared cache are not listed individually; they appear only as the cache file.")
                    .font(.caption).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16).padding(.vertical, 6)
            }
        }
    }

    private static func size(_ bytes: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(clamping: bytes), countStyle: .memory)
    }
}

// MARK: - Signing

private struct SigningTab: View {
    let model: InspectorModel
    @State private var query = ""
    @State private var selection = Set<String>()

    var body: some View {
        switch model.signing {
        case .loading: Spinner()
        case .failed(let msg, let helper): HelperNote(text: msg, needsHelper: helper)
        case .loaded(let details):
            if let d = details {
                let ents = InspectorModel.entitlementRows(d)
                let q = query.lowercased()
                let rows = q.isEmpty ? ents : ents.filter { $0.key.lowercased().contains(q) || $0.value.lowercased().contains(q) }
                VStack(spacing: 0) {
                    Grid(alignment: .topLeading, horizontalSpacing: 16, verticalSpacing: 6) {
                        line("Status", d.status.label)
                        line("Team ID", d.teamID ?? "—")
                        line("Identifier", d.identifier ?? "—")
                        line("Notarized", d.notarized ? "Yes" : "No")
                        line("Hardened runtime", d.hardenedRuntime ? "Yes" : "No")
                        line("Certificate chain", d.certificateChain.isEmpty ? "—" : d.certificateChain.joined(separator: "\n"))
                    }
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    Divider()
                    SearchBar(text: $query, prompt: "Search \(ents.count) entitlements", trailing: AnyView(
                        Button("Copy all") { copy(rows.map { "\($0.key) = \($0.value)" }.joined(separator: "\n")) }
                            .disabled(rows.isEmpty)))
                    if ents.isEmpty {
                        HelperNote(text: "No entitlements.", needsHelper: false)
                    } else {
                        Table(rows, selection: $selection) {
                            TableColumn("Entitlement") { Text($0.key).lineLimit(1) }.width(min: 200, ideal: 340)
                            TableColumn("Value") { Text($0.value).lineLimit(1) }
                        }
                        .contextMenu(forSelectionType: String.self) { keys in
                            Button("Copy") {
                                copy(rows.filter { keys.contains($0.key) }.map { "\($0.key) = \($0.value)" }.joined(separator: "\n"))
                            }
                        }
                    }
                }
            } else {
                HelperNote(text: model.sample.path == nil
                           ? "The executable path is not readable."
                           : "Unsigned, or the code signature could not be read.",
                           needsHelper: model.isRestricted && model.sample.path == nil)
            }
        }
    }

    private func line(_ title: String, _ value: String) -> some View {
        GridRow {
            Text(title).foregroundStyle(.secondary).gridColumnAlignment(.trailing)
            Text(value).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
        }
    }
}
