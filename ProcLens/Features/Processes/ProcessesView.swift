import ProcLensCore
import SwiftUI

struct ProcessesView: View {
    @Environment(AppModel.self) private var model
    @Environment(ProcessActionCenter.self) private var actions
    @State private var vm = ProcessesViewModel()
    @State private var selection: [ProcessID] = []

    var body: some View {
        VStack(spacing: 0) {
            TotalsBar(vm: vm)
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

private struct TotalsBar: View {
    let vm: ProcessesViewModel

    var body: some View {
        HStack(spacing: 24) {
            stat("CPU", vm.totals.cpu)
            stat("Memory", vm.totals.memory)
            stat("Disk", vm.totals.disk)
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .accessibilityElement(children: .combine)
    }

    private func stat(_ title: String, _ value: String) -> some View {
        HStack(spacing: 6) {
            Text(title).foregroundStyle(.secondary)
            Text(value).fontWeight(.semibold).monospacedDigit()
                .frame(width: 72, alignment: .leading)
        }
        .font(.callout)
    }
}
