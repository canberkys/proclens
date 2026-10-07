import SwiftUI

struct DetailsView: View {
    @Environment(AppModel.self) private var model
    @State private var vm = DetailsViewModel()

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
            onSelectionChange: { ids in Task { @MainActor in vm.setSelected(ids) } }
        )
        .searchable(text: $vm.searchText, placement: .toolbar, prompt: "Search name, PID or path")
        .navigationTitle("Details")
        .background {
            TickDriver(model: model) { vm.rebuild(model: model) }
        }
        .onChange(of: vm.searchText) { vm.rebuild(model: model) }
    }
}
