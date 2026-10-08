import ProcLensCore
import SwiftUI

/// Windows-style "End task" toolbar button: acts on the table selection, disabled without one.
struct EndTaskToolbarItem: ToolbarContent {
    @Environment(ProcessActionCenter.self) private var actions
    let selection: [ProcessID]

    var body: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            Button {
                actions.request(.quit, on: selection)
            } label: {
                Label("End task", systemImage: "xmark.circle")
            }
            .disabled(selection.isEmpty)
            .help("End the selected process (Delete)")
            .accessibilityLabel("End task")
            .accessibilityHint("Asks the selected processes to quit, after confirmation")
        }
        ToolbarItem(placement: .primaryAction) {
            Button {
                actions.request(.properties, on: selection)
            } label: {
                Label("Properties", systemImage: "info.circle")
            }
            .keyboardShortcut("i", modifiers: .command)
            .disabled(selection.isEmpty)
            .help("Open the inspector for the selected process (⌘I)")
            .accessibilityLabel("Properties")
        }
    }
}
