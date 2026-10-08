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
        TableColumnSpec(id: "cpu", title: "CPU", width: 80, alignment: .right, monospacedDigits: true, spoken: true),
        TableColumnSpec(id: "memory", title: "Memory", width: 90, alignment: .right, monospacedDigits: true, spoken: true),
        TableColumnSpec(id: "energy", title: "Energy", width: 90, alignment: .right),
        TableColumnSpec(id: "disk", title: "Disk", width: 90, alignment: .right, monospacedDigits: true),
        TableColumnSpec(id: "network", title: "Network", width: 90, alignment: .right, hiddenByDefault: true,
                        headerTooltip: "Phase 2"),
        TableColumnSpec(id: "gpu", title: "GPU", width: 80, alignment: .right, hiddenByDefault: true,
                        headerTooltip: "Phase 2"),
    ]

    @ObservationIgnored let feed = TableFeed()
    @ObservationIgnored private(set) var totals = Totals()
    /// Set by the totals strip; called (only on change) instead of publishing through `@Observable`.
    @ObservationIgnored var totalsSink: ((Totals) -> Void)?
    var searchText = ""
    var sort: TableSort {
        didSet { UserDefaults.standard.set([sort.key, sort.ascending ? "1" : "0"], forKey: Self.sortKey) }
    }

    private static let sortKey = "ProcLens.processes.sort"

    /// Tooltip for every value the sampler could not read for a root-owned process.
    static let restrictedTip = "Not permitted without the helper (Phase 2)"
    static let dash = "—"

    init() {
        if let s = UserDefaults.standard.array(forKey: Self.sortKey) as? [String], s.count == 2,
           Self.columns.contains(where: { $0.id == s[0] }) {
            sort = TableSort(key: s[0], ascending: s[1] == "1")
        } else {
            sort = TableSort(key: "name", ascending: true)
        }
    }

    // MARK: - Per-process cache

    /// Quantized view of everything a row displays; equal sig => the cached row is still right.
    private struct Sig: Equatable {
        var cpuTenths: Int32
        var memory: UInt64
        var energy: Int32
        var disk: Int64
        var restricted: Bool
    }

    /// One live process. Static data is computed once; the row is rebuilt only when `sig` changes.
    private final class Entry {
        var s: ProcessSample
        let group: ProcessGroup
        var owner: ProcessID?
        var ppid: pid_t
        let displayName: String
        let nameKey: String
        /// First 8 UTF-8 bytes of `nameKey`, big-endian: integer compare decides almost every name comparison.
        let nameRank: UInt64
        let isApp: Bool
        let nameTip: String?
        var haystack: String?
        // Current (for apps: aggregated with children) values.
        var cpu = 0.0, energy = 0.0, disk = 0.0
        var memory: UInt64 = 0
        var restricted = false
        var sig: Sig?
        var row: TableRowData?
        var iconTries = 0

        init(sample p: ProcessSample, group: ProcessGroup, displayName: String, isApp: Bool) {
            s = p
            ppid = p.ppid
            self.group = group
            self.displayName = displayName
            self.isApp = isApp
            nameKey = displayName.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            var rank: UInt64 = 0
            var n = 0
            for b in nameKey.utf8.prefix(8) { rank = rank << 8 | UInt64(b); n += 1 }
            nameRank = rank << UInt64((8 - n) * 8)
            if let entry = DaemonNameMap.shared.entry(for: p.name) {
                nameTip = p.path.map { "\(entry.title)\n\($0)" } ?? entry.title
            } else {
                nameTip = p.path
            }
        }

        func loadOwnValues() {
            restricted = s.isRestricted
            cpu = s.cpu; memory = s.memory; energy = s.energy
            disk = s.diskReadPerSec + s.diskWritePerSec
        }

        func matches(_ query: String) -> Bool {
            if haystack == nil {
                haystack = "\(displayName)\n\(s.name)\n\(s.pid)\n\(s.path ?? "")".lowercased()
            }
            return haystack!.contains(query)
        }
    }

    private struct Stamp: Equatable {
        var epoch: Int
        var sortKey: String
        var ascending: Bool
    }

    private struct Context {
        let cores: Double
        let memTotal: Double
    }

    @ObservationIgnored private var cache: [ProcessID: Entry] = [:]
    @ObservationIgnored private var iconCache: [pid_t: NSImage] = [:]
    @ObservationIgnored private var appsRevision = -1
    @ObservationIgnored private var lastCount = -1
    @ObservationIgnored private var lastQuery = ""
    /// Bumped whenever membership, filter or app mapping changes (invalidates cached structure/order).
    @ObservationIgnored private var epoch = 0
    /// Bumped only when the filter or app mapping changes (cached rows of collapsed nodes stay valid otherwise).
    @ObservationIgnored private var filterEpoch = 0
    @ObservationIgnored private var structureEpoch = -1
    @ObservationIgnored private var topLevel: [ProcessGroup: [Entry]] = [:]
    @ObservationIgnored private var allKids: [ProcessID: [Entry]] = [:]
    @ObservationIgnored private var filteredTop: [ProcessGroup: [Entry]] = [:]
    @ObservationIgnored private var filteredKids: [ProcessID: [Entry]] = [:]
    @ObservationIgnored private var orderCache: [NodeID: (stamp: Stamp, list: [Entry])] = [:]
    @ObservationIgnored private var emitted: [NodeID: (stamp: Stamp, rows: [TableRowData])] = [:]
    /// App rows holding matching children (expanded on a new search) and the exact PID match, if any.
    @ObservationIgnored private var revealIDs: [NodeID] = []
    @ObservationIgnored private var focusID: ProcessID?
    @ObservationIgnored private var expandedIDs: Set<NodeID> = [.group(.apps), .group(.background), .group(.system)]
    @ObservationIgnored private var nextRev: UInt64 = 0
    @ObservationIgnored private weak var lastModel: AppModel?

    /// Called by the table when the user expands/collapses a node. Expanding a node whose children were
    /// not refreshed while collapsed rebuilds immediately.
    func expansionChanged(_ ids: Set<NodeID>) {
        let grew = !ids.subtracting(expandedIDs).isEmpty
        expandedIDs = ids
        if grew, let model = lastModel { rebuild(model: model) }
    }

    // MARK: - Build

    func rebuild(model: AppModel) {
        lastModel = model
        guard let snapshot = model.latest else { return }
        updateTotals(snapshot)
        guard let table = snapshot.processes else { return }

        let grouper = model.grouper
        let query = searchText.trimmingCharacters(in: .whitespaces).lowercased()
        var dirty = false
        if appsRevision != model.appsRevision {
            appsRevision = model.appsRevision
            cache.removeAll(keepingCapacity: true)
            emitted.removeAll()
            filterEpoch &+= 1
            dirty = true
        }
        var queryChanged = false
        if query != lastQuery { lastQuery = query; filterEpoch &+= 1; dirty = true; queryChanged = true }
        if table.processes.count != lastCount { lastCount = table.processes.count; dirty = true }

        // Pass 1: refresh samples; create entries for new processes.
        var fresh: [Entry] = []
        var reparented = false
        for p in table.processes.values {
            if let e = cache[p.id] {
                e.s = p
                if p.ppid != e.ppid { e.ppid = p.ppid; reparented = true }
                e.loadOwnValues()
            } else {
                let g = grouper.group(for: p)
                let name = g == .apps ? (model.runningApps[p.pid]?.localizedName ?? p.name) : p.name
                let e = Entry(sample: p, group: g, displayName: name, isApp: g == .apps)
                e.loadOwnValues()
                cache[p.id] = e
                fresh.append(e)
            }
        }
        if !fresh.isEmpty || reparented { dirty = true }
        if dirty {
            if cache.count > table.processes.count + 256 {
                cache = cache.filter { table.processes[$0.key] != nil }
                emitted = emitted.filter { entry in
                    switch entry.key {
                    case .group: true
                    case .process(let id): table.processes[id] != nil
                    }
                }
            }
            orderCache.removeAll(keepingCapacity: true)
            epoch &+= 1
            assignOwners(table: table, grouper: grouper, fresh: fresh, all: reparented)
            rebuildStructure(table: table)
        }
        // Aggregate children into app rows.
        for e in topLevel[.apps] ?? [] {
            for k in allKids[e.s.id] ?? [] where !k.restricted {
                e.cpu += k.cpu; e.memory += k.memory; e.energy += k.energy; e.disk += k.disk
            }
        }
        if structureEpoch != epoch { rebuildFilter(query: query) }
        if queryChanged { feed.newSearch(reveal: revealIDs, focus: focusID) }

        let ctx = Context(cores: Double(max(1, snapshot.cpu?.cores.count ?? 1)),
                          memTotal: Double(snapshot.memory?.total ?? 0))
        let stamp = Stamp(epoch: epoch, sortKey: sort.key, ascending: sort.ascending)
        let freezeStamp = Stamp(epoch: filterEpoch, sortKey: sort.key, ascending: sort.ascending)

        var out: [TableRowData] = []
        for group in ProcessGroup.allCases {
            let list = filteredTop[group] ?? []
            if list.isEmpty { continue }
            let title: String = switch group {
            case .apps: "Apps"
            case .background: "Background processes"
            case .system: "System processes"
            }
            var row = TableRowData(id: .group(group), cells: Array(repeating: "", count: Self.columns.count))
            row.cells[0] = "\(title) (\(list.count))"
            row.isGroup = true
            let gid = NodeID.group(group)
            if !expandedIDs.contains(gid), let old = emitted[gid], old.stamp == freezeStamp {
                row.children = old.rows
                row.childrenFrozen = true
            } else {
                row.children = ordered(list, key: gid, stamp: stamp).map { buildNode($0, ctx: ctx, stamp: stamp, freeze: freezeStamp) }
                emitted[gid] = (freezeStamp, row.children)
            }
            out.append(row)
        }
        feed.push(out)
    }

    /// Nearest `.apps` ancestor for new entries (or for everything when a parent changed).
    private func assignOwners(table: ProcessTable, grouper: ProcessGrouper, fresh: [Entry], all: Bool) {
        let targets: [Entry] = all ? Array(cache.values) : fresh
        guard !targets.isEmpty else { return }
        var byPID: [pid_t: ProcessSample] = [:]
        byPID.reserveCapacity(table.processes.count)
        for p in table.processes.values { byPID[p.pid] = p }
        for e in targets {
            e.owner = nil
            var visited: Set<pid_t> = [e.s.pid]
            var parentPID = e.s.ppid
            var depth = 0
            while depth < 32 {
                guard visited.insert(parentPID).inserted, let parent = byPID[parentPID] else { break }
                let pg = cache[parent.id]?.group ?? grouper.group(for: parent)
                if pg == .apps { e.owner = parent.id; break }
                parentPID = parent.ppid
                depth += 1
            }
        }
    }

    private func rebuildStructure(table: ProcessTable) {
        topLevel.removeAll(keepingCapacity: true)
        allKids.removeAll(keepingCapacity: true)
        for (_, e) in cache where table.processes[e.s.id] != nil {
            if e.group != .apps, let owner = e.owner {
                allKids[owner, default: []].append(e)
            } else {
                topLevel[e.group, default: []].append(e)
            }
        }
    }

    private func rebuildFilter(query: String) {
        structureEpoch = epoch
        filteredTop.removeAll(keepingCapacity: true)
        filteredKids.removeAll(keepingCapacity: true)
        revealIDs = []
        focusID = nil
        if let pid = Int32(query), let hit = cache.values.first(where: { $0.s.pid == pid && topLevelOrKid($0) }) {
            focusID = hit.s.id
            if let owner = hit.owner, hit.group != .apps { revealIDs.append(.process(owner)) }
        }
        for group in ProcessGroup.allCases {
            var list: [Entry] = []
            for e in topLevel[group] ?? [] {
                if group == .apps {
                    let kids = allKids[e.s.id] ?? []
                    let selfMatch = query.isEmpty || e.matches(query)
                    let shown = selfMatch ? kids : kids.filter { $0.matches(query) }
                    if !selfMatch && shown.isEmpty { continue }
                    filteredKids[e.s.id] = shown
                    if !selfMatch { revealIDs.append(.process(e.s.id)) }
                    list.append(e)
                } else if query.isEmpty || e.matches(query) {
                    list.append(e)
                }
            }
            filteredTop[group] = list
        }
    }

    /// Entries of dead processes can linger in `cache`; only live ones are in the structure.
    private func topLevelOrKid(_ e: Entry) -> Bool {
        topLevel[e.group]?.contains { $0 === e } == true || e.owner.flatMap { allKids[$0] }?.contains { $0 === e } == true
    }

    private func buildNode(_ e: Entry, ctx: Context, stamp: Stamp, freeze: Stamp) -> TableRowData {
        var row = makeRow(e, ctx: ctx)
        guard e.isApp, let kids = filteredKids[e.s.id], !kids.isEmpty else {
            emitted[.process(e.s.id)] = nil
            return row
        }
        let nid = NodeID.process(e.s.id)
        if !expandedIDs.contains(nid), let old = emitted[nid], old.stamp == freeze {
            row.children = old.rows
            row.childrenFrozen = true
        } else {
            row.children = ordered(kids, key: nid, stamp: stamp).map { makeRow($0, ctx: ctx) }
            emitted[nid] = (freeze, row.children)
        }
        return row
    }

    private func ordered(_ list: [Entry], key: NodeID, stamp: Stamp) -> [Entry] {
        let asc = sort.ascending
        if sort.key == "name" {
            if let c = orderCache[key], c.stamp == stamp { return c.list }
            // Sort plain (rank, index) pairs: no reference counting in the comparator.
            struct Key { var rank: UInt64; var idx: Int32 }
            var keys = [Key]()
            keys.reserveCapacity(list.count)
            for (i, e) in list.enumerated() { keys.append(Key(rank: e.nameRank, idx: Int32(i))) }
            keys.sort { a, b in
                if a.rank != b.rank { return asc ? a.rank < b.rank : a.rank > b.rank }
                let x = list[Int(a.idx)], y = list[Int(b.idx)]
                if x.nameKey != y.nameKey { return asc ? x.nameKey < y.nameKey : x.nameKey > y.nameKey }
                return x.s.pid < y.s.pid
            }
            let sorted = keys.map { list[Int($0.idx)] }
            orderCache[key] = (stamp, sorted)
            return sorted
        }
        struct Key { var v: Double; var r: Bool; var pid: pid_t; var idx: Int32 }
        var keys = [Key]()
        keys.reserveCapacity(list.count)
        for (i, e) in list.enumerated() {
            let v: Double = switch sort.key {
            case "cpu": e.cpu
            case "memory": Double(e.memory)
            case "energy": e.energy
            default: e.disk
            }
            keys.append(Key(v: v, r: e.restricted, pid: e.s.pid, idx: Int32(i)))
        }
        keys.sort { a, b in
            if a.r != b.r { return !a.r }          // unreadable ("—") always last
            if a.v != b.v { return asc ? a.v < b.v : a.v > b.v }
            return a.pid < b.pid
        }
        return keys.map { list[Int($0.idx)] }
    }

    private func updateTotals(_ s: SystemSnapshot) {
        var t = Totals()
        if let cpu = s.cpu { t.cpu = Format.percent(cpu.total) }
        if let mem = s.memory, mem.total > 0 { t.memory = Format.percent(Double(mem.used) / Double(mem.total)) }
        if let disk = s.disk { t.disk = Format.rate(disk.readPerSec + disk.writePerSec) }
        if t != totals { totals = t; totalsSink?(t) }
    }

    private func makeRow(_ e: Entry, ctx: Context) -> TableRowData {
        let cpuTenths = Int32((e.cpu / ctx.cores * 1000).rounded())
        let memQ = e.memory < 1_048_576 ? e.memory : (e.memory >> 15) << 15
        let sig = Sig(cpuTenths: cpuTenths, memory: memQ, energy: Int32(min(e.energy, 1e6)),
                      disk: Int64(min(e.disk, 1e15) / 100), restricted: e.restricted)
        if let row = e.row, e.sig == sig, !(e.isApp && row.icon == nil && e.iconTries < 3) { return row }

        let p = e.s
        var cells = [String](repeating: "", count: Self.columns.count)
        cells[0] = e.displayName
        var row: TableRowData
        if e.restricted {
            for i in 1...4 { cells[i] = Self.dash }
            row = TableRowData(id: .process(p.id), cells: cells)
            row.heat = [0, 0, 0, 0, 0, 0, 0]
        } else {
            let cpu = Double(cpuTenths) / 1000
            cells[1] = FastFormat.percent(cpu)
            cells[2] = FastFormat.bytes(memQ)
            cells[3] = Self.energyLabel(e.energy)
            cells[4] = FastFormat.rate(e.disk)
            row = TableRowData(id: .process(p.id), cells: cells)
            row.heat = [0,
                        Self.quantize(Heat.scale(cpu, reference: 0.25)),
                        Self.quantize(Heat.scale(Double(memQ), reference: max(1, ctx.memTotal * 0.10))),
                        Self.quantize(Heat.scale(e.energy, reference: 150)),
                        Self.quantize(Heat.scale(e.disk, reference: 20_000_000)), 0, 0]
        }
        if e.isApp {
            if let img = iconCache[p.pid] { row.icon = img } else {
                e.iconTries += 1
                if let img = Self.icon(for: p.pid) { iconCache[p.pid] = img; row.icon = img }
            }
        } else {
            row.icon = ProcessIcons.generic
        }
        var tip: [Int: String] = [:]
        if let t = e.nameTip { tip[0] = t }
        if e.restricted { for i in 1...4 { tip[i] = Self.restrictedTip } }
        row.tooltips = tip
        nextRev &+= 1
        row.rev = nextRev
        e.sig = sig
        e.row = row
        return row
    }

    private static func quantize(_ h: Float) -> Float { (h * 20).rounded() / 20 }

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
}
