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

    private static let restrictedTip = "Not permitted without the helper"
    private static let restrictedTooltips: [Int: String] = [Col.path: restrictedTip, Col.cmdline: restrictedTip, Col.sign: restrictedTip]
    private static let cmdTooltips: [Int: String] = [Col.cmdline: restrictedTip, Col.sign: restrictedTip]
    private static let sortKey = "ProcLens.details.sort"

    private(set) var rows: [TableRowData] = []
    var searchText = ""
    var sort: TableSort {
        didSet { UserDefaults.standard.set([sort.key, sort.ascending ? "1" : "0"], forKey: Self.sortKey) }
    }

    /// Values that never change for a process lifetime (or change rarely), formatted once.
    private struct Static {
        var ppid: pid_t
        let pidText: String
        var ppidText: String
        let user: String
        let arch: String
        let start: String
        let path: String
    }

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
        list.sort { a, b in
            let r = self.compare(a, b, key: key)
            if r == .orderedSame { return a.pid < b.pid }
            return asc ? r == .orderedAscending : r == .orderedDescending
        }

        var out: [TableRowData] = []
        out.reserveCapacity(list.count)
        for p in list {
            let s = staticInfo(for: p)
            var cells = [String](repeating: "", count: Self.columns.count)
            cells[Col.pid] = s.pidText
            cells[Col.name] = p.name
            cells[Col.ppid] = s.ppidText
            cells[Col.user] = s.user
            cells[Col.arch] = s.arch
            cells[Col.threads] = String(p.threadCount)
            cells[Col.cpu] = FastFormat.percent(p.cpu / coreCount)
            cells[Col.memory] = FastFormat.bytes(p.memory)
            cells[Col.start] = s.start
            var row = TableRowData(id: .process(p.id), cells: cells)
            if p.isRestricted {
                row.cells[Col.path] = s.path
                row.cells[Col.cmdline] = "—"
                row.cells[Col.sign] = "—"
                row.tooltips = p.path == nil ? Self.restrictedTooltips : Self.cmdTooltips
            } else {
                row.cells[Col.path] = s.path
                row.cells[Col.cmdline] = cmdlines[p.id] ?? ""
                row.cells[Col.sign] = p.path.flatMap { signing[$0] } ?? ""
            }
            out.append(row)
        }
        rows = out

        if statics.count > table.processes.count * 2 + 64 {
            statics = statics.filter { table.processes[$0.key] != nil }
            cmdlines = cmdlines.filter { table.processes[$0.key] != nil }
        }
        fetchMissing()
    }

    private func staticInfo(for p: ProcessSample) -> Static {
        if var s = statics[p.id] {
            if s.ppid != p.ppid {
                s.ppid = p.ppid
                s.ppidText = String(p.ppid)
                statics[p.id] = s
            }
            return s
        }
        let start = Date(timeIntervalSince1970: Double(p.id.startTime) / 1_000_000)
        let s = Static(
            ppid: p.ppid, pidText: String(p.pid), ppidText: String(p.ppid), user: userName(p.uid),
            arch: p.isTranslated ? "Intel (Rosetta)" : Self.nativeArch,
            start: dateFormatter.string(from: start),
            path: p.path ?? (p.isRestricted ? "—" : "—")
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

    private func compare(_ a: ProcessSample, _ b: ProcessSample, key: String) -> ComparisonResult {
        func cmp<T: Comparable>(_ x: T, _ y: T) -> ComparisonResult {
            x < y ? .orderedAscending : (x > y ? .orderedDescending : .orderedSame)
        }
        switch key {
        case "pid": return cmp(a.pid, b.pid)
        case "ppid": return cmp(a.ppid, b.ppid)
        case "user": return userName(a.uid).caseInsensitiveCompare(userName(b.uid))
        case "arch": return cmp(a.isTranslated ? 1 : 0, b.isTranslated ? 1 : 0)
        case "threads": return cmp(a.threadCount, b.threadCount)
        case "cpu": return cmp(a.cpu, b.cpu)
        case "memory": return cmp(a.memory, b.memory)
        case "path": return (a.path ?? "").caseInsensitiveCompare(b.path ?? "")
        case "cmdline": return (cmdlines[a.id] ?? "").caseInsensitiveCompare(cmdlines[b.id] ?? "")
        case "start": return cmp(a.id.startTime, b.id.startTime)
        case "sign": return (a.path.flatMap { signing[$0] } ?? "").caseInsensitiveCompare(b.path.flatMap { signing[$0] } ?? "")
        default: return a.name.caseInsensitiveCompare(b.name)
        }
    }
}
