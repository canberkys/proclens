import SwiftUI

@main
struct ProcLensApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        Window("ProcLens", id: "main") {
            ContentView()
                .environment(model)
                .task {
                    model.start()
                    #if DEBUG
                    DebugSnapshot.scheduleIfRequested()
                    #endif
                }
                .frame(minWidth: 900, minHeight: 600)
        }

        MenuBarExtra {
            MenuBarContent()
                .environment(model)
        } label: {
            MenuBarLabel(model: model)
        }

        Settings {
            SettingsView()
                .environment(model)
        }
    }
}
