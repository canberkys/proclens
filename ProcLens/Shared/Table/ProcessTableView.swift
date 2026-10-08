import AppKit
import ProcLensCore
import SwiftUI

/// One generic wrapper over `NSOutlineView`: grouped rows (Processes) or a flat list (Details,
/// no row has children). Rows are diffed by `NodeID` and applied incrementally (SPEC §2):
/// removals, moves, insertions, then `reloadData(forRowIndexes:)` for changed visible rows only.
struct ProcessTableView: NSViewRepresentable {
    let autosaveName: String
    let columns: [TableColumnSpec]
    let feed: TableFeed
    let sort: TableSort
    var onSortChange: (TableSort) -> Void
    var onVisibleIDsChange: (([ProcessID]) -> Void)?
    var onSelectionChange: (([ProcessID]) -> Void)?
    var onExpansionChange: ((Set<NodeID>) -> Void)?
    var handler: any ProcessActionHandler
    /// Column that carries the disclosure triangles / indentation; nil = the first column.
    var outlineColumnID: String?
    /// Tree mode: nodes with children start expanded; only nodes the user collapsed stay collapsed.
    var expandByDefault = false
    /// Double-click on a process row always opens it (even if it has children, which expand via the triangle).
    var doubleClickOpens = false

    init(autosaveName: String, columns: [TableColumnSpec], feed: TableFeed, sort: TableSort,
         onSortChange: @escaping (TableSort) -> Void,
         onVisibleIDsChange: (([ProcessID]) -> Void)? = nil,
         onSelectionChange: (([ProcessID]) -> Void)? = nil,
         onExpansionChange: ((Set<NodeID>) -> Void)? = nil,
         handler: any ProcessActionHandler,
         outlineColumnID: String? = nil, expandByDefault: Bool = false, doubleClickOpens: Bool = false) {
        self.outlineColumnID = outlineColumnID
        self.expandByDefault = expandByDefault
        self.doubleClickOpens = doubleClickOpens
        self.autosaveName = autosaveName
        self.columns = columns
        self.feed = feed
        self.sort = sort
        self.onSortChange = onSortChange
        self.onVisibleIDsChange = onVisibleIDsChange
        self.onSelectionChange = onSelectionChange
        self.onExpansionChange = onExpansionChange
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
        c.syncOutlineColumn()
        c.attach(feed)
    }

    // MARK: - Coordinator

    @MainActor
    final class Coordinator: NSObject, NSOutlineViewDataSource, NSOutlineViewDelegate, NSMenuDelegate {
        var parent: ProcessTableView
        private let outline = ActionOutlineView()
        private let contextMenu = NSMenu()
        private let headerMenu = NSMenu()
        private var roots: [TableNode] = []
        /// Built lazily (only selection restore needs it) and invalidated by structural changes.
        private var index: [NodeID: TableNode] = [:]
        private var indexValid = false
        private var expanded: Set<NodeID> = [.group(.apps), .group(.background), .group(.system)]
        /// `expandByDefault` mode: nodes the user collapsed (everything else with children is expanded).
        private var collapsed: Set<NodeID> = []
        private var lastReloadToken = 0
        private func shouldExpand(_ id: NodeID) -> Bool {
            parent.expandByDefault ? !collapsed.contains(id) : expanded.contains(id)
        }
        private var suppressCallbacks = false
        private var structureChanged = false
        /// `beginUpdates` is only issued when a tick actually changes structure (it is surprisingly costly).
        private var batching = false
        private func batch() { if !batching { batching = true; outline.beginUpdates() } }
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

        private weak var attachedFeed: TableFeed?

        func attach(_ feed: TableFeed) {
            guard attachedFeed !== feed else { return }
            attachedFeed = feed
            feed.onPush = { [weak self] rows in self?.apply(rows) }
            apply(feed.rows)
        }

        func syncOutlineColumn() {
            let want = parent.outlineColumnID.flatMap { id in outline.tableColumns.first { $0.identifier.rawValue == id } }
                ?? outline.tableColumns.first
            guard let want, outline.outlineTableColumn !== want else { return }
            outline.outlineTableColumn = want
            outline.needsDisplay = true
        }

        func syncSortDescriptors() {
            let want = parent.sort
            if let d = outline.sortDescriptors.first, d.key == want.key, d.ascending == want.ascending { return }
            suppressCallbacks = true
            outline.sortDescriptors = [NSSortDescriptor(key: want.key, ascending: want.ascending)]
            outline.headerView?.needsDisplay = true
            suppressCallbacks = false
        }

        // MARK: Diff apply

        func apply(_ newRows: [TableRowData]) {
            let selectedBefore = selectedNodeIDs()
            var changed: [NodeID: IndexSet] = [:]
            var inserted: [TableNode] = []

            suppressCallbacks = true
            defer { suppressCallbacks = false }

            let token = attachedFeed?.reloadToken ?? 0
            let forceReload = token != lastReloadToken
            lastReloadToken = token
            if roots.isEmpty || newRows.isEmpty || forceReload {
                // Initial population (or everything filtered away): a single bulk load, never per tick.
                roots = newRows.map(TableNode.init)
                outline.reloadData()
                inserted = flatten(roots)
                indexValid = false
            } else {
                batching = false
                roots = sync(parent: nil, old: roots, new: newRows, changed: &changed, inserted: &inserted)
                if batching { outline.endUpdates(); batching = false }
            }

            if !inserted.isEmpty || structureChanged { indexValid = false }
            structureChanged = false

            for node in inserted where !node.children.isEmpty && shouldExpand(node.id) {
                outline.expandItem(node)
            }

            // Refresh the visible cells whose content changed, in place (no row reload machinery).
            if !changed.isEmpty {
                let range = outline.rows(in: outline.visibleRect)
                if range.length > 0 {
                    for r in range.location..<(range.location + range.length) {
                        guard let node = outline.item(atRow: r) as? TableNode, let cols = changed[node.id] else { continue }
                        for c in cols where c < outline.numberOfColumns {
                            if let cell = outline.view(atColumn: c, row: r, makeIfNecessary: false) as? HeatCellView {
                                configure(cell, node: node, columnIdentifier: outline.tableColumns[c].identifier)
                            }
                        }
                    }
                }
            }

            // Preserve selection across structural changes.
            if selectedNodeIDs() != selectedBefore {
                if !indexValid {
                    index.removeAll(keepingCapacity: true)
                    for node in flatten(roots) { index[node.id] = node }
                    indexValid = true
                }
                var set = IndexSet()
                for id in selectedBefore {
                    if let node = index[id] {
                        let r = outline.row(forItem: node)
                        if r >= 0 { set.insert(r) }
                    }
                }
                outline.selectRowIndexes(set, byExtendingSelection: false)
            }
            applySearchRequest(feed: attachedFeed)
            reportVisible()
            reportSelection()
        }

        private var lastSearchToken = 0

        /// A new search expands the app rows that hold matching children and selects an exact PID match.
        private func applySearchRequest(feed: TableFeed?) {
            guard let feed, feed.searchToken != lastSearchToken else { return }
            lastSearchToken = feed.searchToken
            if !indexValid {
                index.removeAll(keepingCapacity: true)
                for node in flatten(roots) { index[node.id] = node }
                indexValid = true
            }
            for id in feed.reveal {
                if let node = index[id], !node.children.isEmpty, !outline.isItemExpanded(node) { outline.expandItem(node) }
            }
            if let focus = feed.focus, let node = index[.process(focus)] {
                let r = outline.row(forItem: node)
                if r >= 0 {
                    outline.selectRowIndexes([r], byExtendingSelection: false)
                    outline.scrollRowToVisible(r)
                }
            }
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
                          changed: inout [NodeID: IndexSet], inserted: inout [TableNode]) -> [TableNode] {
            // A node gaining or losing all children changes its disclosure state: reload just that node.
            if let parent, old.isEmpty != new.isEmpty {
                structureChanged = true
                let fresh = new.map(TableNode.init)
                parent.children = fresh
                if self.parent.expandByDefault { inserted.append(parent) }
                inserted.append(contentsOf: flatten(fresh))
                batch()
                outline.reloadItem(parent, reloadChildren: true)
                return fresh
            }
            if old.isEmpty && new.isEmpty { return old }

            let newIDs = new.map(\.id)
            // Fast path: identical order and membership.
            if old.count == new.count, zip(old, newIDs).allSatisfy({ $0.id == $1 }) {
                for (node, d) in zip(old, new) {
                    update(node, with: d, changed: &changed)
                    if d.childrenFrozen { continue }
                    node.children = sync(parent: node, old: node.children, new: d.children, changed: &changed, inserted: &inserted)
                }
                return old
            }

            structureChanged = true
            batch()
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
            for (node, d) in staged where !d.childrenFrozen {
                node.children = sync(parent: node, old: node.children, new: d.children, changed: &changed, inserted: &inserted)
            }
            return final
        }

        private func update(_ node: TableNode, with d: TableRowData, changed: inout [NodeID: IndexSet]) {
            if node.data.rev != 0 && node.data.rev == d.rev { return }
            if !node.data.sameCells(as: d) {
                let cols = d.changedColumns(from: node.data)
                if !cols.isEmpty { changed[d.id] = cols }
            }
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

        func outlineView(_ outlineView: NSOutlineView, rowViewForItem item: Any) -> NSTableRowView? {
            guard let node = item as? TableNode else { return nil }
            let id = NSUserInterfaceItemIdentifier("ProcLensRow")
            let row = (outline.makeView(withIdentifier: id, owner: nil) as? SummaryRowView) ?? {
                let r = SummaryRowView(frame: .zero)
                r.identifier = id
                return r
            }()
            row.node = node
            row.summarize = { [weak self] node in self?.summary(of: node) ?? "" }
            return row
        }

        /// VoiceOver text for a row: "Google Chrome, CPU 3 percent, Memory 4.6 gigabytes".
        private func summary(of node: TableNode) -> String {
            let d = node.data
            let cols = parent.columns
            if d.isGroup {
                let state = outline.isItemExpanded(node) ? "expanded" : "collapsed"
                return "\(d.cells.first ?? ""), group, \(state)"
            }
            var parts: [String] = []
            if let n = cols.firstIndex(where: { $0.id == "name" }), n < d.cells.count { parts.append(d.cells[n]) }
            for (i, spec) in cols.enumerated() where spec.spoken && i < d.cells.count {
                let v = d.cells[i]
                if v.isEmpty || v == ProcessesViewModel.dash { continue }
                parts.append("\(spec.title) \(Self.spoken(v))")
            }
            if !node.children.isEmpty {
                parts.append("\(node.children.count) child processes, \(outline.isItemExpanded(node) ? "expanded" : "collapsed")")
            }
            return parts.joined(separator: ", ")
        }

        private static func spoken(_ v: String) -> String {
            v.replacingOccurrences(of: "%", with: " percent")
                .replacingOccurrences(of: " GB", with: " gigabytes")
                .replacingOccurrences(of: " MB", with: " megabytes")
                .replacingOccurrences(of: " KB", with: " kilobytes")
                .replacingOccurrences(of: " bytes", with: " bytes")
                .replacingOccurrences(of: "/s", with: " per second")
        }

        func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
            guard let node = item as? TableNode, let tableColumn,
                  columnIndex[tableColumn.identifier.rawValue] != nil else { return nil }
            let cell = (outlineView.makeView(withIdentifier: tableColumn.identifier, owner: nil) as? HeatCellView) ?? {
                let c = HeatCellView(frame: .zero)
                c.identifier = tableColumn.identifier
                return c
            }()
            configure(cell, node: node, columnIdentifier: tableColumn.identifier)
            return cell
        }

        private func configure(_ cell: HeatCellView, node: TableNode, columnIdentifier: NSUserInterfaceItemIdentifier) {
            guard let ci = columnIndex[columnIdentifier.rawValue] else { return }
            let spec = parent.columns[ci]
            let d = node.data
            let text = ci < d.cells.count ? d.cells[ci] : ""
            let name = d.cells.first ?? ""
            cell.configure(text: text, icon: spec.showsIcon ? d.icon : nil, showsIcon: spec.showsIcon,
                           heat: ci < d.heat.count ? d.heat[ci] : 0, alignment: spec.alignment,
                           isGroup: d.isGroup && ci == 0, monospaced: spec.monospacedDigits,
                           tooltip: d.tooltips[ci], accessibility: ci == 0 ? text : "\(name), \(spec.title): \(text)")
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
            if let node = notification.userInfo?["NSObject"] as? TableNode {
                expanded.insert(node.id)
                if !suppressCallbacks { collapsed.remove(node.id) }
            }
            reportVisible()
            parent.onExpansionChange?(expanded)
        }

        func outlineViewItemDidCollapse(_ notification: Notification) {
            if let node = notification.userInfo?["NSObject"] as? TableNode {
                expanded.remove(node.id)
                if !suppressCallbacks { collapsed.insert(node.id) }
            }
            reportVisible()
            parent.onExpansionChange?(expanded)
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
            if let pid = node.id.processID, node.children.isEmpty || parent.doubleClickOpens {
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

        /// Return: expand/collapse selected rows that have children (apps, groups); the rest go to the handler.
        private func returnKey() {
            var rest: [ProcessID] = []
            for r in outline.selectedRowIndexes {
                guard let node = outline.item(atRow: r) as? TableNode else { continue }
                if !node.children.isEmpty {
                    if outline.isItemExpanded(node) { outline.collapseItem(node) } else { outline.expandItem(node) }
                } else if let pid = node.id.processID {
                    rest.append(pid)
                }
            }
            if !rest.isEmpty { parent.handler.open(rest) }
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
            // Group header rows get no process actions.
            if row >= 0, (outline.item(atRow: row) as? TableNode)?.id.processID == nil { contextIDs = []; return }
            contextIDs = selectedProcessIDs()
            guard !contextIDs.isEmpty else { return }
            for entry in ProcessAction.menuLayout {
                guard let action = entry else { menu.addItem(.separator()); continue }
                if action == .endTree && contextIDs.count != 1 { continue }
                let item = NSMenuItem(title: action.title, action: #selector(contextAction(_:)), keyEquivalent: action == .properties ? "i" : "")
                if action == .properties { item.keyEquivalentModifierMask = .command }
                item.target = self
                item.representedObject = action.rawValue
                menu.addItem(item)
            }
        }
    }
}
