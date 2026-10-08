import SwiftUI

/// Closures the main window publishes so menu commands can drive its sheets.
struct WindowActions {
    var showEndByPID: () -> Void
    var showAbout: () -> Void
}

extension FocusedValues {
    @Entry var windowActions: WindowActions?
}

/// Add with `.commands { ProcLensCommands() }` on the main `Window` scene.
struct ProcLensCommands: Commands {
    @FocusedValue(\.windowActions) private var window

    var body: some Commands {
        CommandGroup(replacing: .appInfo) {
            Button("About ProcLens") { window?.showAbout() }
                .disabled(window == nil)
        }
        CommandMenu("Process") {
            Button("End process by PID…") { window?.showEndByPID() }
                // ⌘K is bound on the toolbar button in ContentView; binding it here too would clash.
                .disabled(window == nil)
        }
    }
}
