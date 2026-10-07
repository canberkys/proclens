import AppKit
import Observation
import ProcLensCore

@Observable @MainActor
final class ProcessesViewModel {
    struct Totals: Equatable {
        var cpu = "—"
        var memory = "—"
        var disk = "—"
    }

    static let columns: [TableColumnSpec] = [
        TableColumnSpec(id: "name", title: "Name", width: 280, minWidth: 140, showsIcon: true, canHide: false),
        TableColumnSpec(id: "cpu", title: "CPU", width: 80, alignment: .right, monospacedDigits: true),
        TableColumnSpec(id: "memory", title: "Memory", width: 90, alignment: .right, monospacedDigits: true),
        TableColumnSpec(id: "energy", title: "Energy", width: 90, alignment: .right),
        TableColumnSpec(id: "disk", title: "Disk", width: 90, alignment: .right, monospacedDigits: true),
        TableColumnSpec(id: "network", title: "Network", width: 90, alignment: .right, hiddenByDefault: true,
                        headerTooltip: "Phase 2"),
        TableColumnSpec(id: "gpu", title: "GPU", width: 80, alignment: .right, hiddenByDefault: true,
                        headerTooltip: "Phase 2"),
    ]

    private(set) var rows: [TableRowData] = []
    private(set) var totals = Totals()
    var searchText = ""
    var sort: TableSort {
        didSet { UserDefaults.standard.set([sort.key, sort.ascending ? "1" : "0"], forKey: Self.sortKey) }
    }

    private static let sortKey = "ProcLens.processes.sort"

    @ObservationIgnored private var iconCache: [pid_t: NSImage] = [:]
    @ObservationIgnored private var tooltipCache: [ProcessID: [Int: String]] = [:]

    init() {
        if let s = UserDefaults.standard.array(forKey: Self.sortKey) as? [String], s.count == 2,
           Self.columns.contains(where: { $0.id == s[0] }) {
            sort = TableSort(key: s[0], ascending: s[1] == "1")
        } else {
            sort = TableSort(key: "name", ascending: true)
        }
    }

    // MARK: - Build

    private struct Item {
        let sample: ProcessSample
        let displayName: String
        var cpu: Double
        var memory: UInt64
        var energy: Double
        var disk: Double
        var kids: [Item] = []
        var isApp = false
    }

    func rebuild(model: AppModel) {
        guard let snapshot = model.latest else { return }
        updateTotals(snapshot)
        guard let table = snapshot.processes else { return }

        let all = Array(table.processes.values)
        let grouper = model.grouper
        let owners = grouper.groupApps(all)
        let query = searchText.trimmingCharacters(in: .whitespaces).lowercased()
        let coreCount = Double(max(1, snapshot.cpu?.cores.count ?? 1))
        let memTotal = Double(snapshot.memory?.total ?? 0)

        var kidsByApp: [ProcessID: [ProcessSample]] = [:]
        var topLevel: [ProcessGroup: [ProcessSample]] = [:]
        for p in all {
            let g = grouper.group(for: p)
            if g != .apps, let owner = owners[p.id] {
                kidsByApp[owner, default: []].append(p)
            } else {
                topLevel[g, default: []].append(p)
            }
        }

        func matches(_ p: ProcessSample, _ displayName: String) -> Bool {
            if query.isEmpty { return true }
            return displayName.lowercased().contains(query) || p.name.lowercased().contains(query)
                || String(p.pid).contains(query) || (p.path?.lowercased().contains(query) ?? false)
        }

        func leaf(_ p: ProcessSample) -> Item {
            Item(sample: p, displayName: p.name, cpu: p.cpu, memory: p.memory, energy: p.energy,
                 disk: p.diskReadPerSec + p.diskWritePerSec)
        }

        var out: [TableRowData] = []
        for group in ProcessGroup.allCases {
            var items: [Item] = []
            for p in topLevel[group] ?? [] {
                if group == .apps {
                    let name = model.runningApps[p.pid]?.localizedName ?? p.name
                    var item = leaf(p)
                    item = Item(sample: p, displayName: name, cpu: item.cpu, memory: item.memory,
                                energy: item.energy, disk: item.disk, kids: [], isApp: true)
                    let kids = (kidsByApp[p.id] ?? []).map(leaf)
                    for k in kids {
                        item.cpu += k.cpu; item.memory += k.memory; item.energy += k.energy; item.disk += k.disk
                    }
                    let selfMatch = matches(p, name)
                    item.kids = selfMatch ? kids : kids.filter { matches($0.sample, $0.displayName) }
                    if !selfMatch && item.kids.isEmpty { continue }
                    item.kids.sort(by: comparator())
                    items.append(item)
                } else if matches(p, p.name) {
                    items.append(leaf(p))
                }
            }
            if items.isEmpty { continue }
            items.sort(by: comparator())
            let title: String = switch group {
            case .apps: "Apps"
            case .background: "Background processes"
            case .system: "System processes"
            }
            var row = TableRowData(id: .group(group), cells: Array(repeating: "", count: Self.columns.count))
            row.cells[0] = "\(title) (\(items.count))"
            row.isGroup = true
            row.children = items.map { makeRow($0, coreCount: coreCount, memTotal: memTotal) }
            out.append(row)
        }
        rows = out
        if tooltipCache.count > all.count * 2 + 64 { tooltipCache.removeAll(keepingCapacity: true) }
    }

    private func updateTotals(_ s: SystemSnapshot) {
        var t = Totals()
        if let cpu = s.cpu { t.cpu = Format.percent(cpu.total) }
        if let mem = s.memory, mem.total > 0 { t.memory = Format.percent(Double(mem.used) / Double(mem.total)) }
        if let disk = s.disk { t.disk = Format.rate(disk.readPerSec + disk.writePerSec) }
        if t != totals { totals = t }
    }

    private func makeRow(_ item: Item, coreCount: Double, memTotal: Double) -> TableRowData {
        let p = item.sample
        var cells = [String](repeating: "", count: Self.columns.count)
        cells[0] = item.displayName
        cells[1] = FastFormat.percent(item.cpu / coreCount)
        cells[2] = FastFormat.bytes(item.memory)
        cells[3] = Self.energyLabel(item.energy)
        cells[4] = FastFormat.rate(item.disk)
        var row = TableRowData(id: .process(p.id), cells: cells)
        row.heat = [0,
                    Heat.scale(item.cpu / coreCount, reference: 0.25),
                    Heat.scale(Double(item.memory), reference: max(1, memTotal * 0.10)),
                    Heat.scale(item.energy, reference: 150),
                    Heat.scale(item.disk, reference: 20_000_000), 0, 0]
        if item.isApp {
            if let img = iconCache[p.pid] { row.icon = img } else if let img = Self.icon(for: p.pid) {
                iconCache[p.pid] = img
                row.icon = img
            }
        } else {
            row.icon = ProcessIcons.generic
        }
        if let tip = tooltipCache[p.id] {
            row.tooltips = tip
        } else {
            var tip: [Int: String] = [:]
            if let entry = DaemonNameMap.shared.entry(for: p.name) {
                tip[0] = p.path.map { "\(entry.title)\n\($0)" } ?? entry.title
            } else if let path = p.path {
                tip[0] = path
            }
            tooltipCache[p.id] = tip
            row.tooltips = tip
        }
        if !item.kids.isEmpty {
            row.children = item.kids.map { makeRow($0, coreCount: coreCount, memTotal: memTotal) }
        }
        return row
    }

    private static func icon(for pid: pid_t) -> NSImage? {
        guard let img = NSRunningApplication(processIdentifier: pid)?.icon else { return nil }
        img.size = NSSize(width: 16, height: 16)
        return img
    }

    private static func energyLabel(_ e: Double) -> String {
        switch e {
        case ..<5: "Very low"
        case ..<25: "Low"
        case ..<75: "Moderate"
        case ..<150: "High"
        default: "Very high"
        }
    }

    private func comparator() -> (Item, Item) -> Bool {
        let key = sort.key, asc = sort.ascending
        return { a, b in
            let r: ComparisonResult
            switch key {
            case "cpu": r = a.cpu < b.cpu ? .orderedAscending : (a.cpu > b.cpu ? .orderedDescending : .orderedSame)
            case "memory": r = a.memory < b.memory ? .orderedAscending : (a.memory > b.memory ? .orderedDescending : .orderedSame)
            case "energy": r = a.energy < b.energy ? .orderedAscending : (a.energy > b.energy ? .orderedDescending : .orderedSame)
            case "disk": r = a.disk < b.disk ? .orderedAscending : (a.disk > b.disk ? .orderedDescending : .orderedSame)
            default: r = a.displayName.caseInsensitiveCompare(b.displayName)
            }
            if r == .orderedSame { return a.sample.pid < b.sample.pid }
            return asc ? r == .orderedAscending : r == .orderedDescending
        }
    }
}
