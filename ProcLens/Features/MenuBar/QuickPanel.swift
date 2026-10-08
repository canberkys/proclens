import SwiftUI
import AppKit
import ProcLensCore

/// Menu bar panel. The body touches the model only while the panel is open, so a closed panel costs nothing per tick.
struct MenuBarContent: View {
    @Environment(AppModel.self) private var model
    @State private var open = false

    var body: some View {
        Group {
            if open { QuickPanel() } else { Color.clear.frame(width: 340, height: 120) }
        }
        .onAppear { open = true; model.setPanelOpen(true) }
        .onDisappear { open = false; model.setPanelOpen(false) }
    }
}

private enum Metric: String, CaseIterable { case cpu = "CPU", memory = "Memory" }

private struct QuickPanel: View {
    @Environment(AppModel.self) private var model
    @Environment(ProcessActionCenter.self) private var actions
    @State private var query = ""
    @State private var metric = Metric.cpu
    @FocusState private var searchFocused: Bool
    @State private var ports = PortsStore()

    var body: some View {
        let snap = model.latest
        let searching = !query.trimmingCharacters(in: .whitespaces).isEmpty
        let rows = topProcesses(snap?.processes?.processes, limit: searching ? 8 : 5)
        VStack(spacing: 10) {
            gauges
            Divider()
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search name or PID", text: $query)
                    .textFieldStyle(.plain).focused($searchFocused)
                if searching {
                    Button { query = "" } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain).foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 8).padding(.vertical, 6)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 7))
            if !searching {
                Picker("", selection: $metric) {
                    ForEach(Metric.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }.pickerStyle(.segmented).labelsHidden()
            }
            VStack(spacing: 0) {
                ForEach(rows) { p in
                    ProcessRow(p: p, metric: metric, actions: actions, icon: model.icon(for: p.pid) ?? BundleIcon.icon(forExecutable: p.path),
                               coreCount: model.latest?.cpu?.cores.count ?? 1)
                }
                if rows.isEmpty {
                    Text(searching ? "No matching processes" : "Collecting…")
                        .font(.callout).foregroundStyle(.secondary).padding(.top, 16)
                }
                Spacer(minLength: 0)
            }
            .frame(height: CGFloat(searching ? 8 : 5) * 28)
            DevServersSection(rows: ports.rows.filter(\.isPanelDevServer), actions: actions)
            Divider()
            footer
        }
        .onAppear { ports.start(model: model) }
        .onDisappear { ports.stop() }
        .padding(12)
        .frame(width: 340)
        .task { try? await Task.sleep(for: .milliseconds(120)); searchFocused = true }
    }

    // MARK: Gauges

    private var gauges: some View {
        let hist = model.history
        let cap = max(2, Int(AppModel.historySeconds / model.interval.rawValue))
        let latest = model.latest
        let cpu = hist.map { $0.cpu?.total ?? 0 }
        let mem = hist.map { $0.memory.map { Double($0.used) / Double(max(1, $0.total)) } ?? 0 }
        let gpu = hist.map { $0.gpu?.utilization ?? 0 }
        let down = hist.map { $0.network?.receivedPerSec ?? 0 }
        let up = hist.map { $0.network?.sentPerSec ?? 0 }
        let netMax = Sparkline.niceMax(max(down.max() ?? 0, up.max() ?? 0))
        let pressure: Color = switch latest?.memory?.pressure { case .warning: .yellow; case .critical: .red; default: .green }
        // 2×2 tiles instead of four full-width rows: half the height, larger values.
        return Grid(horizontalSpacing: 8, verticalSpacing: 8) {
            GridRow {
                GaugeTile(title: "CPU", value: latest?.cpu.map { Format.percent($0.total) } ?? "–") {
                    Sparkline(series: [.init(values: cpu, color: .accentColor)], maxValue: 1, capacity: cap)
                }
                GaugeTile(title: "Memory", value: latest?.memory.map { Format.percent(Double($0.used) / Double(max(1, $0.total))) } ?? "–", dot: pressure) {
                    Sparkline(series: [.init(values: mem, color: .purple)], maxValue: 1, capacity: cap)
                }
            }
            GridRow {
                GaugeTile(title: "GPU", value: latest?.gpu.map { Format.percent($0.utilization) } ?? "–") {
                    Sparkline(series: [.init(values: gpu, color: .orange)], maxValue: 1, capacity: cap)
                }
                GaugeTile(title: "Network",
                          value: "↓\(Format.rate(latest?.network?.receivedPerSec ?? 0))  ↑\(Format.rate(latest?.network?.sentPerSec ?? 0))",
                          small: true) {
                    Sparkline(series: [.init(values: down, color: .green), .init(values: up, color: .blue)], maxValue: netMax, capacity: cap)
                }
            }
        }
    }

    // MARK: Footer

    private var footer: some View {
        HStack {
            Button("Open ProcLens") {
                WindowOpener.showMainWindow()
            }
            Spacer()
            Button { WindowOpener.showSettings() } label: { Image(systemName: "gearshape") }
                .buttonStyle(.borderless).help("Settings")
            Button { NSApplication.shared.terminate(nil) } label: { Image(systemName: "power") }
                .buttonStyle(.borderless).help("Quit ProcLens")
        }
    }

    // MARK: Data

    private func topProcesses(_ table: [ProcessID: ProcessSample]?, limit: Int) -> [ProcessSample] {
        guard let table else { return [] }
        let q = query.trimmingCharacters(in: .whitespaces)
        func key(_ p: ProcessSample) -> Double { metric == .cpu ? p.cpu : Double(p.memory) }
        var out: [ProcessSample] = []
        let exact = Int32(q)
        var first: ProcessSample?
        for p in table.values {
            if !q.isEmpty {
                if p.pid == exact { first = p; continue }
                guard p.name.range(of: q, options: [.caseInsensitive, .diacriticInsensitive]) != nil
                        || String(p.pid).contains(q) else { continue }
            }
            // Small insertion list: top `limit` only.
            if out.count == limit, key(p) <= key(out[limit - 1]) { continue }
            let i = out.firstIndex { key($0) < key(p) } ?? out.count
            out.insert(p, at: i)
            if out.count > limit { out.removeLast() }
        }
        if let first { out.insert(first, at: 0); if out.count > limit { out.removeLast() } }
        return out
    }
}

private struct GaugeTile<Chart: View>: View {
    let title: String
    let value: String
    var dot: Color?
    var small = false
    @ViewBuilder let chart: Chart

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(title).font(.caption).foregroundStyle(.secondary)
                if let dot { Circle().fill(dot).frame(width: 6, height: 6) }
                Spacer(minLength: 2)
                Text(value)
                    .font(small ? .caption.monospacedDigit() : .headline.monospacedDigit())
                    .lineLimit(1).minimumScaleFactor(0.8)
            }
            chart.frame(height: 24)
        }
        .padding(8)
        .frame(maxWidth: .infinity)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 8))
        .accessibilityElement(children: .combine)
    }
}

private struct ProcessRow: View {
    let p: ProcessSample
    let metric: Metric
    let actions: ProcessActionCenter
    let icon: NSImage?
    let coreCount: Int
    @State private var hovering = false
    private static let generic = NSWorkspace.shared.icon(for: .unixExecutable)

    var body: some View {
        HStack(spacing: 8) {
            Image(nsImage: icon ?? Self.generic).resizable().frame(width: 18, height: 18)
            Text(p.name).lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 4)
            if hovering {
                Button { actions.request(.quit, on: [p.id]) } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.plain).foregroundStyle(.secondary).help("End task")
            }
            Text(value).font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                .frame(width: 64, alignment: .trailing)
        }
        .padding(.horizontal, 6).frame(height: 28)
        .background(hovering ? AnyShapeStyle(.quaternary) : AnyShapeStyle(.clear), in: RoundedRectangle(cornerRadius: 6))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .contextMenu {
            Button("End Task") { actions.request(.quit, on: [p.id]) }
            Button("Force Quit") { actions.request(.forceQuit, on: [p.id]) }
            Divider()
            Button("Reveal in Finder") { actions.request(.revealInFinder, on: [p.id]) }
            Button("Copy PID") { actions.request(.copyPID, on: [p.id]) }
        }
    }

    private var value: String {
        if p.isRestricted { return "—" }
        // Share of the whole machine, like the Processes tab and Windows Task Manager.
        return metric == .cpu ? Format.percentOneDecimal(p.cpu / Double(max(1, coreCount))) : Format.bytes(p.memory)
    }
}

/// Icon of the outermost `.app` bundle containing an executable, so helpers
/// (e.g. "Google Chrome Helper (Renderer)") show their app's icon. Cached per bundle.
@MainActor
enum BundleIcon {
    private static var cache: [String: NSImage] = [:]

    static func icon(forExecutable path: String?) -> NSImage? {
        #if DEBUG
        if DemoMode.isActive { return DemoMode.icon(forExecutable: path) }
        #endif
        guard let path, let range = path.range(of: ".app/") else { return nil }
        let bundle = String(path[..<range.lowerBound]) + ".app"
        if let cached = cache[bundle] { return cached }
        let image = NSWorkspace.shared.icon(forFile: bundle)
        if cache.count > 200 { cache.removeAll() }
        cache[bundle] = image
        return image
    }
}

/// Up to five listening dev servers (web/runtime by rule). Hidden when there are none.
private struct DevServersSection: View {
    let rows: [PortRow]
    let actions: ProcessActionCenter

    var body: some View {
        if !rows.isEmpty {
            VStack(alignment: .leading, spacing: 2) {
                Divider().padding(.bottom, 4)
                Text("Dev servers").font(.caption).foregroundStyle(.secondary).padding(.horizontal, 6)
                ForEach(rows.prefix(5)) { r in DevServerRow(r: r, actions: actions) }
            }
        }
    }
}

private struct DevServerRow: View {
    let r: PortRow
    let actions: ProcessActionCenter
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(r.match.category.color).frame(width: 7, height: 7)
            Text(verbatim: "\(r.match.framework) :\(String(r.port)) — \(r.processName)").lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 4)
            if let url = r.url {
                Button { NSWorkspace.shared.open(url) } label: { Image(systemName: "globe") }
                    .buttonStyle(.plain).foregroundStyle(.secondary).help("Open \(url.absoluteString)")
            }
            Button { actions.requestEndTree(r.listener.processID) } label: { Image(systemName: "stop.circle") }
                .buttonStyle(.plain).foregroundStyle(.secondary).help("Stop (end process tree)")
        }
        .font(.callout)
        .padding(.horizontal, 6).frame(height: 26)
        .background(hovering ? AnyShapeStyle(.quaternary) : AnyShapeStyle(.clear), in: RoundedRectangle(cornerRadius: 6))
        .onHover { hovering = $0 }
    }
}
