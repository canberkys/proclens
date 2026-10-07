import Foundation
import Observation
import ProcLensCore

@Observable @MainActor
final class DetailsViewModel {
    static let columns: [TableColumnSpec] = [
        TableColumnSpec(id: "pid", title: "PID", width: 60, minWidth: 40, alignment: .right, monospacedDigits: true, canHide: false),
        TableColumnSpec(id: "name", title: "Name", width: 190, minWidth: 100, showsIcon: false, canHide: false),
        TableColumnSpec(id: "ppid", title: "PPID", width: 60, alignment: .right, monospacedDigits: true),
        TableColumnSpec(id: "user", title: "User", width: 100),
        TableColumnSpec(id: "arch", title: "Architecture", width: 110),
        TableColumnSpec(id: "threads", title: "Threads", width: 60, alignment: .right, monospacedDigits: true),
        TableColumnSpec(id: "cpu", title: "CPU", width: 70, alignment: .right, monospacedDigits: true),
        TableColumnSpec(id: "memory", title: "Memory", width: 85, alignment: .right, monospacedDigits: true),
        TableColumnSpec(id: "path", title: "Path", width: 320, minWidth: 80),
        TableColumnSpec(id: "cmdline", title: "Command line", width: 360, minWidth: 80),
        TableColumnSpec(id: "start", title: "Start time", width: 140),
        TableColumnSpec(id: "sign", title: "Code signing", width: 150),
        TableColumnSpec(id: "ports", title: "Ports", width: 80, hiddenByDefault: true, headerTooltip: "Phase 2"),
    ]

    private enum Col {
        static let pid = 0, name = 1, ppid = 2, user = 3, arch = 4, threads = 5, cpu = 6, memory = 7
        static let path = 8, cmdline = 9, start = 10, sign = 11
    }

    private static let restrictedTip = ProcessesViewModel.restrictedTip
    private static let dash = ProcessesViewModel.dash
    /// Values the sampler cannot read for root-owned processes.
    private static let unreadable = [Col.arch, Col.threads, Col.cpu, Col.memory, Col.cmdline, Col.sign]
    private static let restrictedTooltips: [Int: String] =
        Dictionary(uniqueKeysWithValues: (unreadable + [Col.path]).map { ($0, restrictedTip) })
    private static let cmdTooltips: [Int: String] =
        Dictionary(uniqueKeysWithValues: unreadable.map { ($0, restrictedTip) })
    private static let sortKey = "ProcLens.details.sort"

    @ObservationIgnored let feed = TableFeed()
    var searchText = ""
    var sort: TableSort {
        didSet { UserDefaults.standard.set([sort.key, sort.ascending ? "1" : "0"], forKey: Self.sortKey) }
    }

    /// Values that never change for a process lifetime (or change rarely), formatted once, plus the row cache.
    private final class Static {
        var ppid: pid_t
        let pidText: String
        var ppidText: String
        let user: String
        let userKey: String
        let arch: String
        let start: String
        let path: String
        let nameKey: String
        var pathKey: String?
        var sig: Sig?
        var row: TableRowData?

        init(ppid: pid_t, pidText: String, user: String, arch: String, start: String, path: String, name: String) {
            self.ppid = ppid
            self.pidText = pidText
            ppidText = String(ppid)
            self.user = user
            userKey = user.lowercased()
            self.arch = arch
            self.start = start
            self.path = path
            nameKey = name.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
        }
    }

    private struct Sig: Equatable {
        var cpuTenths: Int32
        var memory: UInt64
        var threads: Int32
        var restricted: Bool
        var ppid: pid_t
        var cmd: String?
        var sign: String?
    }

    @ObservationIgnored private var nextRev: UInt64 = 0

    @ObservationIgnored private weak var model: AppModel?
    @ObservationIgnored private var statics: [ProcessID: Static] = [:]
    @ObservationIgnored private var userNames: [uid_t: String] = [:]
    @ObservationIgnored private var cmdlines: [ProcessID: String] = [:]
    @ObservationIgnored private var cmdInFlight: Set<ProcessID> = []
    @ObservationIgnored private var signing: [String: String] = [:]
    @ObservationIgnored private var signInFlight: Set<String> = []
    @ObservationIgnored private var visible: [ProcessID] = []
    @ObservationIgnored private var selected: [ProcessID] = []
    @ObservationIgnored private var rebuildScheduled = false
    @ObservationIgnored private var samples: [ProcessID: ProcessSample] = [:]

    @ObservationIgnored private let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .short
        f.timeStyle = .medium
        return f
    }()

    init() {
        if let s = UserDefaults.standard.array(forKey: Self.sortKey) as? [String], s.count == 2,
           Self.columns.contains(where: { $0.id == s[0] }) {
            sort = TableSort(key: s[0], ascending: s[1] == "1")
        } else {
            sort = TableSort(key: "pid", ascending: true)
        }
    }

    // MARK: - Lazy fetch

    func setVisible(_ ids: [ProcessID]) { visible = ids; fetchMissing() }
    func setSelected(_ ids: [ProcessID]) { selected = ids; fetchMissing() }

    private func fetchMissing() {
        guard let model else { return }
        for id in Set(visible).union(selected) {
            guard let p = samples[id], !p.isRestricted else { continue }
            if cmdlines[id] == nil, cmdInFlight.insert(id).inserted {
                Task { [weak self] in
                    let text: String
                    if let args = try? await model.arguments(for: id) {
                        text = args.arguments.isEmpty ? args.executablePath : args.arguments.joined(separator: " ")
                    } else {
                        text = "—"
                    }
                    guard let self else { return }
                    self.cmdlines[id] = text
                    self.cmdInFlight.remove(id)
                    self.scheduleRebuild()
                }
            }
            if let path = p.path, signing[path] == nil, signInFlight.insert(path).inserted {
                Task { [weak self] in
                    let status = await CodeSignatureInspector.shared.status(forPath: path)
                    guard let self else { return }
                    self.signing[path] = status.label
                    self.signInFlight.remove(path)
                    self.scheduleRebuild()
                }
            }
        }
    }

    private func scheduleRebuild() {
        guard !rebuildScheduled else { return }
        rebuildScheduled = true
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(150))
            guard let self else { return }
            self.rebuildScheduled = false
            if let model = self.model { self.rebuild(model: model) }
        }
    }

    // MARK: - Build

    func rebuild(model: AppModel) {
        self.model = model
        guard let snapshot = model.latest, let table = snapshot.processes else { return }
        samples = table.processes
        let coreCount = Double(max(1, snapshot.cpu?.cores.count ?? 1))
        let query = searchText.trimmingCharacters(in: .whitespaces).lowercased()

        var list: [ProcessSample] = []
        list.reserveCapacity(table.processes.count)
        for p in table.processes.values {
            if !query.isEmpty {
                let hit = p.name.lowercased().contains(query) || String(p.pid).contains(query)
                    || (p.path?.lowercased().contains(query) ?? false)
                if !hit { continue }
            }
            list.append(p)
        }
        let key = sort.key
        let asc = sort.ascending
        let infos = list.map { staticInfo(for: $0) }
        var order = Array(list.indices)
        switch key {
        case "pid", "ppid", "arch", "threads", "cpu", "memory", "start":
            let vals: [Double] = list.map { p in
                switch key {
                case "pid": Double(p.pid)
                case "ppid": Double(p.ppid)
                case "arch": p.isTranslated ? 1 : 0
                case "threads": Double(p.threadCount)
                case "cpu": p.cpu
                case "memory": Double(p.memory)
                default: Double(p.id.startTime)
                }
            }
            let unreadableKey = ["arch", "threads", "cpu", "memory"].contains(key)
            order.sort { i, j in
                if unreadableKey, list[i].isRestricted != list[j].isRestricted { return !list[i].isRestricted }
                if vals[i] != vals[j] { return asc ? vals[i] < vals[j] : vals[i] > vals[j] }
                return list[i].pid < list[j].pid
            }
        default:
            let keys: [String] = list.indices.map { i in
                let p = list[i]
                switch key {
                case "user": return infos[i].userKey
                case "path":
                    if infos[i].pathKey == nil { infos[i].pathKey = (p.path ?? "").lowercased() }
                    return infos[i].pathKey!
                case "cmdline": return (cmdlines[p.id] ?? "").lowercased()
                case "sign": return (p.path.flatMap { signing[$0] } ?? "").lowercased()
                default: return infos[i].nameKey
                }
            }
            order.sort { i, j in
                if keys[i] != keys[j] { return asc ? keys[i] < keys[j] : keys[i] > keys[j] }
                return list[i].pid < list[j].pid
            }
        }

        var out: [TableRowData] = []
        out.reserveCapacity(list.count)
        for i in order {
            let p = list[i]
            let s = infos[i]
            let cpuTenths = Int32((p.cpu / coreCount * 1000).rounded())
            let memQ = p.memory < 1_048_576 ? p.memory : (p.memory >> 15) << 15
            let cmd = p.isRestricted ? nil : cmdlines[p.id]
            let sign = p.isRestricted ? nil : p.path.flatMap { signing[$0] }
            let sig = Sig(cpuTenths: cpuTenths, memory: memQ, threads: p.threadCount, restricted: p.isRestricted,
                          ppid: p.ppid, cmd: cmd, sign: sign)
            if let row = s.row, s.sig == sig {
                out.append(row)
                continue
            }
            var cells = [String](repeating: "", count: Self.columns.count)
            cells[Col.pid] = s.pidText
            cells[Col.name] = p.name
            cells[Col.ppid] = s.ppidText
            cells[Col.user] = s.user
            cells[Col.start] = s.start
            cells[Col.path] = s.path
            var row: TableRowData
            if p.isRestricted {
                for c in Self.unreadable { cells[c] = Self.dash }
                row = TableRowData(id: .process(p.id), cells: cells)
                row.tooltips = p.path == nil ? Self.restrictedTooltips : Self.cmdTooltips
            } else {
                cells[Col.arch] = s.arch
                cells[Col.threads] = String(p.threadCount)
                cells[Col.cpu] = FastFormat.percent(Double(cpuTenths) / 1000)
                cells[Col.memory] = FastFormat.bytes(memQ)
                cells[Col.cmdline] = cmd ?? ""
                cells[Col.sign] = sign ?? ""
                row = TableRowData(id: .process(p.id), cells: cells)
            }
            nextRev &+= 1
            row.rev = nextRev
            s.sig = sig
            s.row = row
            out.append(row)
        }
        feed.push(out)

        if statics.count > table.processes.count * 2 + 64 {
            statics = statics.filter { table.processes[$0.key] != nil }
            cmdlines = cmdlines.filter { table.processes[$0.key] != nil }
        }
        fetchMissing()
    }

    private func staticInfo(for p: ProcessSample) -> Static {
        if let s = statics[p.id] {
            if s.ppid != p.ppid {
                s.ppid = p.ppid
                s.ppidText = String(p.ppid)
            }
            return s
        }
        let start = Date(timeIntervalSince1970: Double(p.id.startTime) / 1_000_000)
        let s = Static(
            ppid: p.ppid, pidText: String(p.pid), user: userName(p.uid),
            arch: p.isTranslated ? "Intel (Rosetta)" : Self.nativeArch,
            start: dateFormatter.string(from: start), path: p.path ?? "—", name: p.name
        )
        statics[p.id] = s
        return s
    }

    private static let nativeArch: String = {
        #if arch(arm64)
        "Apple"
        #else
        "Intel"
        #endif
    }()

    private func userName(_ uid: uid_t) -> String {
        if let cached = userNames[uid] { return cached }
        var pwd = passwd()
        var result: UnsafeMutablePointer<passwd>?
        var buffer = [CChar](repeating: 0, count: 1024)
        var name = String(uid)
        if getpwuid_r(uid, &pwd, &buffer, buffer.count, &result) == 0, result != nil {
            name = String(cString: pwd.pw_name)
        }
        userNames[uid] = name
        return name
    }
}
