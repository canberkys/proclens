import OSLog
import SwiftUI

enum SidebarItem: String, CaseIterable, Identifiable {
    case processes = "Processes"
    case performance = "Performance"
    case details = "Details"
    case networkPorts = "Network Ports"
    case startup = "Startup"
    case services = "Services"

    var id: String { rawValue }

    var symbol: String {
        switch self {
        case .processes: "list.bullet.rectangle"
        case .performance: "chart.xyaxis.line"
        case .details: "tablecells"
        case .networkPorts: "network"
        case .startup: "power"
        case .services: "gearshape.2"
        }
    }

    var isAvailable: Bool {
        switch self {
        case .processes, .performance, .details: true
        case .networkPorts, .startup, .services: false
        }
    }
}

struct ContentView: View {
    #if DEBUG
    @State private var selection: SidebarItem? = DebugSnapshot.initialTab ?? .processes
    #else
    @State private var selection: SidebarItem? = .processes
    #endif

    @Environment(AppModel.self) private var model
    @Environment(ProcessActionCenter.self) private var actions
    @State private var showEndByPID = false
    @State private var showAbout = false
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        NavigationSplitView {
            List(SidebarItem.allCases, selection: $selection) { item in
                NavigationLink(value: item) {
                    HStack {
                        Label(item.rawValue, systemImage: item.symbol)
                        if !item.isAvailable {
                            Spacer()
                            Text("Phase 2")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .disabled(!item.isAvailable)
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 200, max: 260)
            .safeAreaInset(edge: .bottom) {
                Button { showAbout = true } label: {
                    Label("About", systemImage: "info.circle")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .accessibilityLabel("About ProcLens")
            }
        } detail: {
            switch selection ?? .processes {
            case .processes: ProcessesView()
            case .performance: PerformanceView()
            case .details: DetailsView()
            case .networkPorts: NetworkPortsView()
            case .startup: StartupView()
            case .services: ServicesView()
            }
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { showEndByPID = true } label: {
                    Label("End process by PID…", systemImage: "number.circle")
                }
                .keyboardShortcut("k", modifiers: .command)
                .help("End process by PID (⌘K)")
                .accessibilityLabel("End process by PID")
            }
        }
        .background(NoRestoration())
        .onAppear { WindowOpener.openMain = { openWindow(id: "main") } }
        .sheet(isPresented: $showEndByPID) { EndByPIDSheet() }
        .sheet(isPresented: $showAbout) { AboutView() }
        .focusedSceneValue(\.windowActions, WindowActions(showEndByPID: { showEndByPID = true },
                                                            showAbout: { showAbout = true }))
        #if DEBUG
        .task { await SelfTest.runIfRequested(model: model, actions: actions) }
        #endif
    }
}

#if DEBUG
/// `-ProcLensSelfTestEndPID <pid>`: ends that process through `ProcessActionCenter` without UI automation,
/// after asking to end PID 1 and ProcLens itself (both must be refused); logs the results and quits.
@MainActor
enum SelfTest {
    static func runIfRequested(model: AppModel, actions: ProcessActionCenter) async {
        let raw = UserDefaults.standard.integer(forKey: "ProcLensSelfTestEndPID")
        guard raw > 0 else { return }
        func log(_ s: String) {
            print("SELFTEST \(s)")
            fflush(stdout)
            Logger(subsystem: "com.canberkki.ProcLens", category: "selftest").info("\(s, privacy: .public)")
        }
        for _ in 0..<100 where model.latest?.processes == nil { try? await Task.sleep(for: .milliseconds(100)) }
        let pid = pid_t(raw)
        // Refusals first, while the full sampler's table is certainly present (never confirmed, nothing is ended).
        actions.requestEnd(pid: 1)
        log("PID 1: pending=\(actions.pending != nil) message=\(actions.message ?? "nil")")
        actions.message = nil
        actions.requestEnd(pid: getpid())
        log("self(\(getpid())): pending=\(actions.pending != nil) message=\(actions.message ?? "nil")")
        actions.message = nil
        actions.requestEnd(pid: pid)
        if let p = actions.pending {
            log("pending: \(p.action.title) \(p.targets.map { "\($0.name)(\($0.pid))" })")
            actions.confirm()
        } else {
            log("no confirmation pending; message=\(actions.message ?? "nil")")
        }
        try? await Task.sleep(for: .milliseconds(1500))
        log("after confirm: message=\(actions.message ?? "nil") alive=\(kill(pid, 0) == 0)")
        NSApp.terminate(nil)
    }
}
#endif

/// Turns off AppKit window state restoration for the hosting window. Its flush scheduler re-encodes and
/// snapshots the window whenever it redraws, which was a measurable share of our per-tick CPU.
struct NoRestoration: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { Hook() }
    func updateNSView(_ view: NSView, context: Context) {}

    private final class Hook: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            window?.isRestorable = false
        }
    }
}
