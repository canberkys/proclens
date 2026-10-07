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
            sort: vm.sort,
            onSortChange: { newSort in
                guard newSort != vm.sort else { return }
                vm.sort = newSort
                vm.rebuild(model: model)
            },
            onVisibleIDsChange: { ids in Task { @MainActor in vm.setVisible(ids) } },
            onSelectionChange: { ids in Task { @MainActor in vm.setSelected(ids); selection = ids } },
            handler: CenterActionHandler(actions)
        )
        .searchable(text: $vm.searchText, placement: .toolbar, prompt: "Search name, PID or path")
        .toolbar { EndTaskToolbarItem(selection: selection) }
        .navigationTitle("Details")
        .background {
            TickDriver(model: model) { vm.rebuild(model: model) }
        }
        .onChange(of: vm.searchText) { vm.rebuild(model: model) }
    }
}
