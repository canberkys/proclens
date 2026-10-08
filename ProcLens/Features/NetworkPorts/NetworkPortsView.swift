import AppKit
import ProcLensCore
import SwiftUI

/// Listening TCP/UDP ports mapped to their owning process, with dev-server detection and tree kill.
/// Scans every 2 s only while this view is on screen.
struct NetworkPortsView: View {
    private enum Grouping: String, CaseIterable, Identifiable {
        case devFirst = "Dev servers first"
        case all = "All listeners"
        var id: String { rawValue }
    }

    @Environment(AppModel.self) private var model
    @Environment(ProcessActionCenter.self) private var actions
    @State private var store = PortsStore()
    @State private var query = ""
    @State private var grouping = Grouping.devFirst
    @State private var selection: Set<String> = []

    var body: some View {
        let rows = visibleRows
        VStack(spacing: 0) {
            toolbar
            Divider()
            if !store.loaded {
                ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if rows.isEmpty {
                ContentUnavailableView(query.isEmpty ? "No listening ports" : "No matching ports", systemImage: "network")
            } else {
                if grouping == .devFirst, query.isEmpty, !rows.contains(where: \.isDevServer) {
                    Label("No dev servers running", systemImage: "server.rack")
                        .font(.callout).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 12).padding(.vertical, 6)
                    Divider()
                }
                table(rows)
            }
            Divider()
            footer(count: rows.count)
        }
        .onAppear { store.start(model: model) }
        .onDisappear { store.stop() }
        #if DEBUG
        .task { await PortsSelfTest.runIfRequested(model: model, store: store, actions: actions) }
        #endif
    }

    // MARK: Pieces

    private var toolbar: some View {
        HStack(spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search port, process or framework", text: $query).textFieldStyle(.plain)
                if !query.isEmpty {
                    Button { query = "" } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain).foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 8).padding(.vertical, 5)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 7))
            .frame(maxWidth: 320)
            Picker("", selection: $grouping) {
                ForEach(Grouping.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented).labelsHidden().fixedSize()
            Spacer()
            Button { Task { await store.refresh() } } label: { Label("Refresh", systemImage: "arrow.clockwise") }
                .help("Scan now")
        }
        .padding(10)
    }

    private func table(_ rows: [PortRow]) -> some View {
        Table(rows, selection: $selection) {
            TableColumn("Port") { r in
                Text(String(r.port)).monospacedDigit().fontWeight(r.isDevServer ? .semibold : .regular)
            }.width(min: 44, ideal: 52, max: 70)
            TableColumn("Protocol") { r in Text(r.listener.proto.rawValue.uppercased()).foregroundStyle(.secondary) }
                .width(min: 44, ideal: 50, max: 60)
            TableColumn("Address") { r in
                if r.listener.isLoopbackOnly {
                    Text("localhost only")
                        .font(.caption)
                        .padding(.horizontal, 6).padding(.vertical, 1)
                        .background(.teal.opacity(0.18), in: Capsule())
                        .foregroundStyle(.teal)
                } else {
                    Text(r.addressLabel).foregroundStyle(.secondary)
                }
            }.width(min: 80, ideal: 100, max: 130)
            TableColumn("Process") { r in
                HStack(spacing: 6) {
                    Image(nsImage: icon(for: r)).resizable().frame(width: 16, height: 16)
                    Text(r.processName).lineLimit(1)
                }
            }.width(min: 90, ideal: 130)
            TableColumn("PID") { r in Text(String(r.pid)).monospacedDigit().foregroundStyle(.secondary) }
                .width(min: 44, ideal: 52, max: 70)
            TableColumn("Kind") { r in
                HStack(spacing: 5) {
                    Circle().fill(r.match.category.color).frame(width: 7, height: 7)
                    Text(r.match.framework).lineLimit(1)
                }
                .font(.callout)
                .padding(.horizontal, 7).padding(.vertical, 2)
                .background(r.match.category.color.opacity(0.14), in: Capsule())
                .help("\(r.categoryLabel), confidence \(r.match.confidence)%")
            }.width(min: 100, ideal: 120, max: 160)
            TableColumn("Command line") { r in
                Text(r.commandLine.isEmpty ? "—" : r.commandLine)
                    .lineLimit(1).truncationMode(.middle).foregroundStyle(.secondary)
                    .help(r.commandLine)
            }.width(min: 160, ideal: 260)
            TableColumn("") { r in rowButtons(r) }.width(54)
        }
        .contextMenu(forSelectionType: String.self) { ids in
            let picked = rows.filter { ids.contains($0.id) }
            if let r = picked.first, picked.count == 1 { menu(for: r) }
        } primaryAction: { ids in
            if let r = rows.first(where: { ids.contains($0.id) }), let url = r.url { NSWorkspace.shared.open(url) }
        }
    }

    private func rowButtons(_ r: PortRow) -> some View {
        HStack(spacing: 6) {
            if let url = r.url {
                Button { NSWorkspace.shared.open(url) } label: { Image(systemName: "globe") }
                    .help("Open \(url.absoluteString)")
            }
            Button { actions.requestEndTree(r.listener.processID) } label: { Image(systemName: "stop.circle") }
                .help("End process tree")
        }
        .buttonStyle(.borderless).foregroundStyle(.secondary)
    }

    @ViewBuilder
    private func menu(for r: PortRow) -> some View {
        let id = r.listener.processID
        if let url = r.url {
            Button("Open in Browser") { NSWorkspace.shared.open(url) }
            Button("Copy URL") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(url.absoluteString, forType: .string)
            }
            Divider()
        }
        Button("End Task") { actions.request(.quit, on: [id]) }
        Button("Force Quit") { actions.request(.forceQuit, on: [id]) }
        Button("End Process Tree…") { actions.requestEndTree(id) }
        Divider()
        Button("Reveal in Finder") { actions.request(.revealInFinder, on: [id]) }
            .disabled(r.path == nil)
        Button("Copy PID") { actions.request(.copyPID, on: [id]) }
    }

    private func footer(count: Int) -> some View {
        HStack(spacing: 8) {
            Text("\(count) listener\(count == 1 ? "" : "s")").foregroundStyle(.secondary)
            Spacer()
            if !model.services.helperEnabled {
                Image(systemName: "lock.shield").foregroundStyle(.secondary)
                Text("Ports of system processes need the ProcLens helper").foregroundStyle(.secondary)
                SettingsLink { Text("Open Settings") }
            }
        }
        .font(.callout)
        .padding(.horizontal, 12).padding(.vertical, 7)
    }

    // MARK: Data

    private static let generic = NSWorkspace.shared.icon(for: .unixExecutable)

    private func icon(for r: PortRow) -> NSImage {
        model.icon(for: r.pid) ?? BundleIcon.icon(forExecutable: r.path) ?? Self.generic
    }

    private var visibleRows: [PortRow] {
        var rows = store.rows
        let q = query.trimmingCharacters(in: .whitespaces)
        if !q.isEmpty {
            rows = rows.filter { r in
                String(r.port).contains(q)
                    || r.processName.range(of: q, options: [.caseInsensitive, .diacriticInsensitive]) != nil
                    || r.match.framework.range(of: q, options: .caseInsensitive) != nil
                    || String(r.pid) == q
            }
        }
        // Stable partition: dev servers first, each part keeps the port order.
        if grouping == .devFirst { rows = rows.filter(\.isDevServer) + rows.filter { !$0.isDevServer } }
        return rows
    }
}

#if DEBUG
/// `-ProcLensSelfTestKillPortTree <port>`: resolves the listener on that port, requests a tree kill through
/// `ProcessActionCenter` (a protected PID is checked first and must be refused), confirms it, then reports.
@MainActor
enum PortsSelfTest {
    static func runIfRequested(model: AppModel, store: PortsStore, actions: ProcessActionCenter) async {
        let port = UserDefaults.standard.integer(forKey: "ProcLensSelfTestKillPortTree")
        guard port > 0 else { return }
        func log(_ s: String) { print("SELFTEST \(s)"); fflush(stdout) }
        for _ in 0..<100 where model.latest?.processes == nil { try? await Task.sleep(for: .milliseconds(100)) }
        await store.refresh()
        guard let row = store.rows.first(where: { $0.port == port }) else {
            log("no listener on port \(port)"); NSApp.terminate(nil); return
        }
        log("port \(port) -> \(row.processName) pid \(row.pid) kind=\(row.match.framework) dev=\(row.isDevServer) url=\(row.url?.absoluteString ?? "nil")")
        if let launchd = model.latest?.processes?.processes.values.first(where: { $0.pid == 1 }) {
            actions.requestEndTree(launchd.id)
            log("PID 1 tree: pending=\(actions.pendingTree != nil) message=\(actions.message ?? "nil")")
            actions.message = nil
        }
        actions.requestEndTree(row.listener.processID)
        log("pending tree: \(actions.pendingTree.map { "\($0.root.name)(\($0.root.pid)) +\($0.descendantCount) children" } ?? "nil")")
        actions.confirmTree()
        try? await Task.sleep(for: .seconds(3))
        await store.refresh()
        log("after: port still listed=\(store.rows.contains { $0.port == port }) message=\(actions.message ?? "nil")")
        NSApp.terminate(nil)
    }
}
#endif
