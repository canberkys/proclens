import SwiftUI

struct ProcessesView: View {
    @Environment(AppModel.self) private var model
    @State private var vm = ProcessesViewModel()

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 24) {
                stat("CPU", vm.totals.cpu)
                stat("Memory", vm.totals.memory)
                stat("Disk", vm.totals.disk)
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .accessibilityElement(children: .combine)
            Divider()
            ProcessTableView(
                autosaveName: "ProcLens.processesTable",
                columns: ProcessesViewModel.columns,
                rows: vm.rows,
                sort: vm.sort,
                onSortChange: { newSort in
                    guard newSort != vm.sort else { return }
                    vm.sort = newSort
                    vm.rebuild(model: model)
                }
            )
        }
        .searchable(text: $vm.searchText, placement: .toolbar, prompt: "Search name, PID or path")
        .navigationTitle("Processes")
        .onChange(of: model.latest?.tick, initial: true) { vm.rebuild(model: model) }
        .onChange(of: vm.searchText) { vm.rebuild(model: model) }
        .onChange(of: model.runningApps.count) { vm.rebuild(model: model) }
    }

    private func stat(_ title: String, _ value: String) -> some View {
        HStack(spacing: 6) {
            Text(title).foregroundStyle(.secondary)
            Text(value).fontWeight(.semibold).monospacedDigit()
        }
        .font(.callout)
    }
}
