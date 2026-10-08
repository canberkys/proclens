import ProcLensCore
import SwiftUI

struct DetailsView: View {
    @Environment(AppModel.self) private var model
    @Environment(ProcessActionCenter.self) private var actions
    @State private var vm = DetailsViewModel()
    @State private var selection: [ProcessID] = []

    var body: some View {
        ProcessTableView(
            autosaveName: "ProcLens.detailsTable",
            columns: DetailsViewModel.columns,
            feed: vm.feed,
            sort: vm.activeSort,
            onSortChange: { vm.setSort($0) },
            onVisibleIDsChange: { ids in Task { @MainActor in vm.setVisible(ids) } },
            onSelectionChange: { ids in Task { @MainActor in vm.setSelected(ids); selection = ids } },
            handler: CenterActionHandler(actions, opensInspector: true),
            outlineColumnID: vm.treeMode ? "name" : nil,
            expandByDefault: vm.treeMode,
            doubleClickOpens: true
        )
        .searchable(text: $vm.searchText, placement: .toolbar, prompt: "Search name, PID or path")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Toggle(isOn: $vm.treeMode) {
                    Label("Tree", systemImage: "list.bullet.indent")
                }
                .toggleStyle(.button)
                .help(vm.treeMode
                      ? "Show a flat list"
                      : "Show processes as a parent/child tree (rows keep their place; sort a column to reorder)")
                .accessibilityLabel("Process tree")
            }
            EndTaskToolbarItem(selection: selection)
        }
        .focusedSceneValue(\.selectedProcessIDs, selection)
        .navigationTitle("Details")
        .background {
            TickDriver(model: model) { vm.rebuild(model: model) }
        }
        .onChange(of: vm.searchText) { vm.rebuild(model: model) }
    }
}
