import SwiftUI

@main
struct ProcLensApp: App {
    @State private var model: AppModel
    @State private var actions: ProcessActionCenter

    init() {
        let model = AppModel()
        _model = State(initialValue: model)
        _actions = State(initialValue: ProcessActionCenter(model: model))
    }

    var body: some Scene {
        Window("ProcLens", id: "main") {
            ContentView()
                .environment(model)
                .environment(actions)
                .processActionConfirmation(actions)
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
                .environment(actions)
                .processActionConfirmation(actions)
        } label: {
            MenuBarLabel(model: model)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
                .environment(model)
        }
    }
}
