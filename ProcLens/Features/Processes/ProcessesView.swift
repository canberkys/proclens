import ProcLensCore
import AppKit
import SwiftUI

struct ProcessesView: View {
    @Environment(AppModel.self) private var model
    @Environment(ProcessActionCenter.self) private var actions
    @State private var vm = ProcessesViewModel()
    @State private var selection: [ProcessID] = []

    var body: some View {
        VStack(spacing: 0) {
            TotalsBar(vm: vm).frame(height: 33)
            Divider()
            ProcessTableView(
                autosaveName: "ProcLens.processesTable",
                columns: ProcessesViewModel.columns,
                feed: vm.feed,
                sort: vm.sort,
                onSortChange: { newSort in
                    guard newSort != vm.sort else { return }
                    vm.sort = newSort
                    vm.rebuild(model: model)
                },
                onSelectionChange: { ids in Task { @MainActor in selection = ids } },
                onExpansionChange: { ids in Task { @MainActor in vm.expansionChanged(ids) } },
                handler: CenterActionHandler(actions)
            )
        }
        .searchable(text: $vm.searchText, placement: .toolbar, prompt: "Search name, PID or path")
        .toolbar { EndTaskToolbarItem(selection: selection) }
        .navigationTitle("Processes")
        .background {
            // `visibleSnapshot` stops updating while the window is hidden/occluded: no work then.
            TickDriver(model: model) { vm.rebuild(model: model) }
        }
        .onChange(of: vm.searchText) { vm.rebuild(model: model) }
        .onChange(of: model.appsRevision) { vm.rebuild(model: model) }
    }
}

/// Totals strip drawn with plain labels that the view model updates in place (only when the text changes), so a
/// tick never re-evaluates SwiftUI bodies or re-lays out the hosting view.
private struct TotalsBar: NSViewRepresentable {
    let vm: ProcessesViewModel

    func makeNSView(context: Context) -> TotalsStrip {
        let strip = TotalsStrip()
        vm.totalsSink = { [weak strip] t in strip?.show(t) }
        strip.show(vm.totals)
        return strip
    }

    func updateNSView(_ strip: TotalsStrip, context: Context) {}
}

@MainActor
final class TotalsStrip: NSView {
    private let titles = ["CPU", "Memory", "Disk"]
    private let values = (0..<3).map { _ in NSTextField(labelWithString: "") }
    private var last: [String] = ["", "", ""]

    override init(frame: NSRect) {
        super.init(frame: frame)
        let regular = NSFont.systemFont(ofSize: 13)
        let semibold = NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .semibold)
        for (i, title) in titles.enumerated() {
            let t = NSTextField(labelWithString: title)
            t.font = regular
            t.textColor = .secondaryLabelColor
            t.sizeToFit()
            t.frame.origin = NSPoint(x: 12 + CGFloat(i) * 168, y: 8)
            addSubview(t)
            let v = values[i]
            v.font = semibold
            v.lineBreakMode = .byClipping
            v.frame = NSRect(x: t.frame.maxX + 6, y: 8, width: 72, height: t.frame.height)
            addSubview(v)
        }
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: 33) }

    func show(_ t: ProcessesViewModel.Totals) {
        let new = [t.cpu, t.memory, t.disk]
        guard new != last else { return }
        last = new
        for (field, text) in zip(values, new) { field.stringValue = text }
        setAccessibilityLabel(zip(titles, new).map { "\($0) \($1)" }.joined(separator: ", "))
    }
}
