import AppKit
import ProcLensCore

/// Identity of a table node. Group rows have no process.
enum NodeID: Hashable, Sendable {
    case group(ProcessGroup)
    case process(ProcessID)

    var processID: ProcessID? {
        if case .process(let id) = self { return id }
        return nil
    }
}

struct TableSort: Equatable, Sendable {
    var key: String
    var ascending: Bool
}

struct TableColumnSpec: Identifiable, Sendable {
    let id: String
    let title: String
    var width: CGFloat = 90
    var minWidth: CGFloat = 40
    var alignment: NSTextAlignment = .left
    var hiddenByDefault = false
    var headerTooltip: String?
    /// Draws the row icon and carries the outline disclosure triangle.
    var showsIcon = false
    var monospacedDigits = false
    var canHide = true
    /// Included in the row's VoiceOver summary.
    var spoken = false
}

/// One row, built once per snapshot by a view model. Cells are pre-formatted strings.
struct TableRowData {
    let id: NodeID
    var cells: [String]
    /// 0...1 per column; empty when the row has no heat-map.
    var heat: [Float] = []
    var tooltips: [Int: String] = [:]
    var icon: NSImage?
    var isGroup = false
    var children: [TableRowData] = []
    /// Non-zero when the producer guarantees equal `rev` => equal drawn content (cheap "unchanged" test).
    var rev: UInt64 = 0
    /// The producer did not rebuild `children` (collapsed parent); the table keeps what it already has.
    var childrenFrozen = false

    /// Equality of everything that is drawn for this row itself (children excluded).
    func sameCells(as other: TableRowData) -> Bool {
        if rev != 0 && rev == other.rev { return true }
        return cells == other.cells && heat == other.heat && tooltips == other.tooltips
            && icon === other.icon && isGroup == other.isGroup
    }

    /// Columns whose drawn content differs from `old` (empty when the row looks identical).
    func changedColumns(from old: TableRowData) -> IndexSet {
        if rev != 0 && rev == old.rev { return [] }
        var set = IndexSet()
        for i in 0..<max(cells.count, old.cells.count) {
            let a = i < cells.count ? cells[i] : "", b = i < old.cells.count ? old.cells[i] : ""
            let ha = i < heat.count ? heat[i] : 0, hb = i < old.heat.count ? old.heat[i] : 0
            if a != b || ha != hb || tooltips[i] != old.tooltips[i] { set.insert(i) }
        }
        if icon !== old.icon || isGroup != old.isGroup { set.insert(0) }
        return set
    }
}

/// Heat-map scaling shared by the process tables. Output is 0 (no tint) ... 1 (full tint).
enum Heat {
    /// `value / reference` on a square-root ramp so small loads are still visible.
    static func scale(_ value: Double, reference: Double) -> Float {
        guard value > 0, reference > 0 else { return 0 }
        let h = Float(min(1, (value / reference).squareRoot()))
        return h < 0.05 ? 0 : h
    }
}

enum ProcessIcons {
    @MainActor static let generic: NSImage? = {
        let img = NSImage(systemSymbolName: "gearshape", accessibilityDescription: nil)
        img?.size = NSSize(width: 16, height: 16)
        return img
    }()
}

/// Pushes rows from a view model straight to the table, bypassing the SwiftUI view graph
/// (no body re-evaluation per tick; only the NSOutlineView diff runs).
@MainActor
final class TableFeed {
    private(set) var rows: [TableRowData] = []
    var onPush: (([TableRowData]) -> Void)?
    /// Bumped by the producer when the search query changes; the table then expands `reveal` and selects `focus`.
    private(set) var searchToken = 0
    private(set) var reveal: [NodeID] = []
    private(set) var focus: ProcessID?

    /// Bumped when the whole row structure changes (e.g. flat <-> tree): the table then does one bulk reload.
    private(set) var reloadToken = 0
    func requestReload() { reloadToken &+= 1 }

    func newSearch(reveal: [NodeID], focus: ProcessID?) {
        searchToken &+= 1
        self.reveal = reveal
        self.focus = focus
    }

    func push(_ newRows: [TableRowData]) {
        rows = newRows
        onPush?(newRows)
    }
}
