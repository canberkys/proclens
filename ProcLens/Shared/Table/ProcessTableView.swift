import AppKit
import ProcLensCore
import SwiftUI

/// One generic wrapper over `NSOutlineView`: grouped rows (Processes) or a flat list (Details,
/// no row has children). Rows are diffed by `NodeID` and applied incrementally (SPEC §2):
/// removals, moves, insertions, then `reloadData(forRowIndexes:)` for changed visible rows only.
struct ProcessTableView: NSViewRepresentable {
    let autosaveName: String
    let columns: [TableColumnSpec]
    let rows: [TableRowData]
    let sort: TableSort
    var onSortChange: (TableSort) -> Void
    var onVisibleIDsChange: (([ProcessID]) -> Void)?
    var onSelectionChange: (([ProcessID]) -> Void)?
    var handler: any ProcessActionHandler

    init(autosaveName: String, columns: [TableColumnSpec], rows: [TableRowData], sort: TableSort,
         onSortChange: @escaping (TableSort) -> Void,
         onVisibleIDsChange: (([ProcessID]) -> Void)? = nil,
         onSelectionChange: (([ProcessID]) -> Void)? = nil,
         handler: any ProcessActionHandler = LoggingProcessActionHandler()) {
        self.autosaveName = autosaveName
        self.columns = columns
        self.rows = rows
        self.sort = sort
        self.onSortChange = onSortChange
        self.onVisibleIDsChange = onVisibleIDsChange
        self.onSelectionChange = onSelectionChange
        self.handler = handler
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let c = context.coordinator
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        scroll.documentView = c.setUp()
        scroll.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(c, selector: #selector(Coordinator.scrolled),
                                               name: NSView.boundsDidChangeNotification, object: scroll.contentView)
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        let c = context.coordinator
        c.parent = self
        c.syncSortDescriptors()
        c.apply(rows)
    }

    // MARK: - Coordinator

    @MainActor
    final class Coordinator: NSObject, NSOutlineViewDataSource, NSOutlineViewDelegate, NSMenuDelegate {
        var parent: ProcessTableView
        private let outline = ActionOutlineView()
        private let contextMenu = NSMenu()
        private let headerMenu = NSMenu()
        private var roots: [TableNode] = []
        private var index: [NodeID: TableNode] = [:]
        private var expanded: Set<NodeID> = [.group(.apps), .group(.background), .group(.system)]
        private var suppressCallbacks = false
        private var lastVisible: [ProcessID] = []
        private var lastSelection: [ProcessID] = []
        private var columnIndex: [String: Int] = [:]
        private var hiddenKey: String { "ProcLens.hiddenColumns.\(parent.autosaveName)" }
        /// Beyond this many moves in one level we reload that level instead (still not the whole table).
        private let moveCap = 150

        init(_ parent: ProcessTableView) { self.parent = parent }

        func setUp() -> NSView {
            outline.dataSource = self
            outline.delegate = self
            outline.rowHeight = 22
            outline.intercellSpacing = NSSize(width: 0, height: 0)
            outline.style = .fullWidth
            outline.usesAlternatingRowBackgroundColors = false
            outline.allowsMultipleSelection = true
            outline.allowsColumnReordering = true
            outline.allowsColumnResizing = true
            outline.columnAutoresizingStyle = .noColumnAutoresizing
            outline.indentationPerLevel = 14
            outline.floatsGroupRows = false
            outline.setAccessibilityLabel(parent.autosaveName)

            let stored = UserDefaults.standard.array(forKey: hiddenKey) as? [String]
            for (i, spec) in parent.columns.enumerated() {
                let col = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(spec.id))
                col.title = spec.title
                col.width = spec.width
                col.minWidth = spec.minWidth
                col.maxWidth = 2000
                col.headerCell.alignment = spec.alignment
                col.headerToolTip = spec.headerTooltip
                col.sortDescriptorPrototype = NSSortDescriptor(key: spec.id, ascending: true)
                col.isHidden = stored.map { $0.contains(spec.id) } ?? spec.hiddenByDefault
                outline.addTableColumn(col)
                columnIndex[spec.id] = i
                if i == 0 { outline.outlineTableColumn = col }
            }
            outline.autosaveName = parent.autosaveName
            outline.autosaveTableColumns = true

            contextMenu.delegate = self
            outline.menu = contextMenu
            headerMenu.delegate = self
            outline.headerView?.menu = headerMenu

            outline.target = self
            outline.doubleAction = #selector(doubleClicked)
            outline.onDelete = { [weak self] in self?.deleteKey() }
            outline.onReturn = { [weak self] in self?.returnKey() }
            syncSortDescriptors()
            return outline
        }

        func syncSortDescriptors() {
            let want = parent.sort
            if let d = outline.sortDescriptors.first, d.key == want.key, d.ascending == want.ascending { return }
            suppressCallbacks = true
            outline.sortDescriptors = [NSSortDescriptor(key: want.key, ascending: want.ascending)]
            suppressCallbacks = false
        }

        // MARK: Diff apply

        func apply(_ newRows: [TableRowData]) {
            let selectedBefore = selectedNodeIDs()
            var changed = Set<NodeID>()
            var inserted: [TableNode] = []

            suppressCallbacks = true
            defer { suppressCallbacks = false }

            if roots.isEmpty || newRows.isEmpty {
                // Initial population (or everything filtered away): a single bulk load, never per tick.
                roots = newRows.map(TableNode.init)
                outline.reloadData()
                inserted = flatten(roots)
            } else {
                outline.beginUpdates()
                roots = sync(parent: nil, old: roots, new: newRows, changed: &changed, inserted: &inserted)
                outline.endUpdates()
            }

            index.removeAll(keepingCapacity: true)
            for node in flatten(roots) { index[node.id] = node }

            for node in inserted where !node.children.isEmpty && expanded.contains(node.id) {
                outline.expandItem(node)
            }

            // Reload only visible rows whose content changed.
            if !changed.isEmpty {
                let range = outline.rows(in: outline.visibleRect)
                if range.length > 0 {
                    var rows = IndexSet()
                    for r in range.location..<(range.location + range.length) {
                        if let node = outline.item(atRow: r) as? TableNode, changed.contains(node.id) { rows.insert(r) }
                    }
                    if !rows.isEmpty {
                        outline.reloadData(forRowIndexes: rows, columnIndexes: IndexSet(0..<outline.numberOfColumns))
                    }
                }
            }

            // Preserve selection across structural changes.
            if selectedNodeIDs() != selectedBefore {
                var set = IndexSet()
                for id in selectedBefore {
                    if let node = index[id] {
                        let r = outline.row(forItem: node)
                        if r >= 0 { set.insert(r) }
                    }
                }
                outline.selectRowIndexes(set, byExtendingSelection: false)
            }
            reportVisible()
            reportSelection()
        }

        private func flatten(_ nodes: [TableNode]) -> [TableNode] {
            var out: [TableNode] = []
            out.reserveCapacity(nodes.count)
            for n in nodes {
                out.append(n)
                if !n.children.isEmpty { out.append(contentsOf: flatten(n.children)) }
            }
            return out
        }

        private func children(of parent: TableNode?) -> [TableNode] { parent?.children ?? roots }
        private func setChildren(_ nodes: [TableNode], of parent: TableNode?) {
            if let parent { parent.children = nodes } else { roots = nodes }
        }

        private func sync(parent: TableNode?, old: [TableNode], new: [TableRowData],
                          changed: inout Set<NodeID>, inserted: inout [TableNode]) -> [TableNode] {
            // A node gaining or losing all children changes its disclosure state: reload just that node.
            if let parent, old.isEmpty != new.isEmpty {
                let fresh = new.map(TableNode.init)
                parent.children = fresh
                inserted.append(contentsOf: flatten(fresh))
                outline.reloadItem(parent, reloadChildren: true)
                return fresh
            }
            if old.isEmpty && new.isEmpty { return old }

            let newIDs = new.map(\.id)
            // Fast path: identical order and membership.
            if old.count == new.count, zip(old, newIDs).allSatisfy({ $0.id == $1 }) {
                for (node, d) in zip(old, new) {
                    update(node, with: d, changed: &changed)
                    node.children = sync(parent: node, old: node.children, new: d.children, changed: &changed, inserted: &inserted)
                }
                return old
            }

            let parentExpanded = parent == nil || outline.isItemExpanded(parent)
            var needsReload = !parentExpanded
            let newSet = Set(newIDs)
            var retained: [TableNode] = []
            var removals = IndexSet()
            for (i, n) in old.enumerated() {
                if newSet.contains(n.id) { retained.append(n) } else { removals.insert(i) }
            }

            // 1. Removals (indexes refer to the old order).
            if !removals.isEmpty {
                setChildren(retained, of: parent)
                if !needsReload { outline.removeItems(at: removals, inParent: parent, withAnimation: []) }
            }

            // 2. Moves among retained nodes, one at a time against the evolving order.
            let retainedByID = Dictionary(uniqueKeysWithValues: retained.map { ($0.id, $0) })
            let target = newIDs.filter { retainedByID[$0] != nil }
            var arr = retained
            var moves = 0
            for i in 0..<target.count where arr[i].id != target[i] {
                guard let j = arr[(i + 1)...].firstIndex(where: { $0.id == target[i] }) else { continue }
                let node = arr.remove(at: j)
                arr.insert(node, at: i)
                setChildren(arr, of: parent)
                moves += 1
                if moves > moveCap { needsReload = true }
                if !needsReload { outline.moveItem(at: j, inParent: parent, to: i, inParent: parent) }
            }

            // 3. Insertions (indexes refer to the final order).
            var final: [TableNode] = []
            final.reserveCapacity(new.count)
            var insertIdx = IndexSet()
            var staged: [(TableNode, TableRowData)] = []
            for (i, d) in new.enumerated() {
                if let existing = retainedByID[d.id] {
                    update(existing, with: d, changed: &changed)
                    final.append(existing)
                    staged.append((existing, d))
                } else {
                    let fresh = TableNode(data: d)
                    inserted.append(contentsOf: flatten([fresh]))
                    final.append(fresh)
                    insertIdx.insert(i)
                }
            }
            setChildren(final, of: parent)
            if !insertIdx.isEmpty && !needsReload {
                outline.insertItems(at: insertIdx, inParent: parent, withAnimation: [])
            }
            if needsReload { outline.reloadItem(parent, reloadChildren: true) }

            // 4. Recurse into retained nodes.
            for (node, d) in staged {
                node.children = sync(parent: node, old: node.children, new: d.children, changed: &changed, inserted: &inserted)
            }
            return final
        }

        private func update(_ node: TableNode, with d: TableRowData, changed: inout Set<NodeID>) {
            if !node.data.sameCells(as: d) { changed.insert(d.id) }
            node.data = d
        }

        // MARK: Data source

        func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
            (item as? TableNode)?.children.count ?? roots.count
        }

        func outlineView(_ outlineView: NSOutlineView, child i: Int, ofItem item: Any?) -> Any {
            if let node = item as? TableNode { return node.children[i] }
            return roots[i]
        }

        func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
            !((item as? TableNode)?.children.isEmpty ?? true)
        }

        // MARK: Delegate

        func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
            guard let node = item as? TableNode, let tableColumn,
                  let ci = columnIndex[tableColumn.identifier.rawValue] else { return nil }
            let cell = (outlineView.makeView(withIdentifier: tableColumn.identifier, owner: nil) as? HeatCellView) ?? {
                let c = HeatCellView(frame: .zero)
                c.identifier = tableColumn.identifier
                return c
            }()
            let spec = parent.columns[ci]
            let d = node.data
            let text = ci < d.cells.count ? d.cells[ci] : ""
            let name = d.cells.first ?? ""
            cell.configure(text: text, icon: spec.showsIcon ? d.icon : nil, showsIcon: spec.showsIcon,
                           heat: ci < d.heat.count ? d.heat[ci] : 0, alignment: spec.alignment,
                           isGroup: d.isGroup && ci == 0, monospaced: spec.monospacedDigits,
                           tooltip: d.tooltips[ci], accessibility: ci == 0 ? text : "\(name), \(spec.title): \(text)")
            return cell
        }

        func outlineView(_ outlineView: NSOutlineView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
            guard !suppressCallbacks, let d = outlineView.sortDescriptors.first, let key = d.key else { return }
            parent.onSortChange(TableSort(key: key, ascending: d.ascending))
        }

        func outlineViewSelectionDidChange(_ notification: Notification) {
            guard !suppressCallbacks else { return }
            reportSelection()
        }

        func outlineViewItemDidExpand(_ notification: Notification) {
            if let node = notification.userInfo?["NSObject"] as? TableNode { expanded.insert(node.id) }
            reportVisible()
        }

        func outlineViewItemDidCollapse(_ notification: Notification) {
            if let node = notification.userInfo?["NSObject"] as? TableNode { expanded.remove(node.id) }
            reportVisible()
        }

        // MARK: Reporting

        @objc func scrolled() { reportVisible() }

        private func reportVisible() {
            guard let cb = parent.onVisibleIDsChange else { return }
            let range = outline.rows(in: outline.visibleRect)
            var ids: [ProcessID] = []
            if range.length > 0 {
                for r in range.location..<(range.location + range.length) {
                    if let id = (outline.item(atRow: r) as? TableNode)?.id.processID { ids.append(id) }
                }
            }
            if ids != lastVisible {
                lastVisible = ids
                cb(ids)
            }
        }

        private func reportSelection() {
            guard let cb = parent.onSelectionChange else { return }
            let ids = selectedProcessIDs()
            if ids != lastSelection {
                lastSelection = ids
                cb(ids)
            }
        }

        private func selectedNodeIDs() -> Set<NodeID> {
            Set(outline.selectedRowIndexes.compactMap { (outline.item(atRow: $0) as? TableNode)?.id })
        }

        private func selectedProcessIDs() -> [ProcessID] {
            outline.selectedRowIndexes.compactMap { (outline.item(atRow: $0) as? TableNode)?.id.processID }
        }

        // MARK: Actions

        @objc private func doubleClicked() {
            let row = outline.clickedRow
            guard row >= 0, let node = outline.item(atRow: row) as? TableNode else { return }
            if let pid = node.id.processID, node.children.isEmpty {
                parent.handler.open([pid])
            } else if outline.isItemExpanded(node) {
                outline.collapseItem(node)
            } else {
                outline.expandItem(node)
            }
        }

        private func deleteKey() {
            let ids = selectedProcessIDs()
            if !ids.isEmpty { parent.handler.deletePressed(on: ids) }
        }

        private func returnKey() {
            let ids = selectedProcessIDs()
            if !ids.isEmpty { parent.handler.open(ids) }
        }

        @objc private func contextAction(_ sender: NSMenuItem) {
            guard let raw = sender.representedObject as? String, let action = ProcessAction(rawValue: raw) else { return }
            parent.handler.perform(action, on: contextIDs)
        }

        private var contextIDs: [ProcessID] = []

        @objc private func toggleColumn(_ sender: NSMenuItem) {
            guard let col = outline.tableColumns.first(where: { $0.identifier.rawValue == sender.representedObject as? String })
            else { return }
            col.isHidden.toggle()
            let hidden = outline.tableColumns.filter(\.isHidden).map { $0.identifier.rawValue }
            UserDefaults.standard.set(hidden, forKey: hiddenKey)
        }

        func menuNeedsUpdate(_ menu: NSMenu) {
            menu.removeAllItems()
            if menu === headerMenu {
                for (i, spec) in parent.columns.enumerated() {
                    guard let col = outline.tableColumns.first(where: { $0.identifier.rawValue == spec.id }) else { continue }
                    let item = NSMenuItem(title: spec.title, action: #selector(toggleColumn(_:)), keyEquivalent: "")
                    item.target = self
                    item.representedObject = spec.id
                    item.state = col.isHidden ? .off : .on
                    item.isEnabled = spec.canHide && i != 0
                    if let tip = spec.headerTooltip { item.toolTip = tip }
                    menu.addItem(item)
                }
                return
            }
            let row = outline.clickedRow
            if row >= 0, !outline.selectedRowIndexes.contains(row) {
                outline.selectRowIndexes([row], byExtendingSelection: false)
            }
            contextIDs = selectedProcessIDs()
            guard !contextIDs.isEmpty else { return }
            for action in ProcessAction.allCases {
                let item = NSMenuItem(title: action.title, action: #selector(contextAction(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = action.rawValue
                menu.addItem(item)
                if action == .resume || action == .forceQuit { menu.addItem(.separator()) }
            }
        }
    }
}
