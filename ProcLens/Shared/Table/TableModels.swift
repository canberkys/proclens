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

    /// Equality of everything that is drawn for this row itself (children excluded).
    func sameCells(as other: TableRowData) -> Bool {
        cells == other.cells && heat == other.heat && tooltips == other.tooltips
            && icon === other.icon && isGroup == other.isGroup
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
