import SwiftUI

@main
struct ProcLensApp: App {
    @State private var model: AppModel
    @State private var actions: ProcessActionCenter
    @State private var statusItem: StatusItemController

    init() {
        let model = AppModel()
        _model = State(initialValue: model)
        let actions = ProcessActionCenter(model: model)
        _actions = State(initialValue: actions)
        _statusItem = State(initialValue: StatusItemController(model: model, actions: actions))
        AppPresentation.applyStoredActivationPolicy()
        // Sampling and the menu bar graph must not depend on the window existing (it can be closed or not yet on screen).
        model.start()
        AlertNotifier.shared.start(services: model.services)
        _ = UpdaterController.shared  // starts Sparkle's scheduled checks
        #if DEBUG
        HelperProbe.runIfRequested(model: model)  // signed Debug builds only
        #endif
        #if DEBUG
        DispatchQueue.main.async {  // neither needs the main window (it may never appear on a locked screen)
            PanelSnapshot.scheduleIfRequested()
            HelpDebug.scheduleIfRequested()
            FeedbackDebug.scheduleIfRequested(model: model)
            DebugSnapshot.scheduleIfRequested(model: model, actions: actions)
        }
        #endif
    }

    var body: some Scene {
        Window("ProcLens", id: "main") {
            ContentView()
                .environment(model)
                .environment(actions)
                .processActionConfirmation(actions)
                .globalHotKey()
                .frame(minWidth: 900, minHeight: 600)
        }
        .commands { ProcLensCommands(model: model, actions: actions) }

        Window("ProcLens Help", id: "help") {
            HelpView()
        }
        .defaultSize(width: 860, height: 600)

        Window("Release Notes", id: "releasenotes") {
            ReleaseNotesView()
        }
        .defaultSize(width: 560, height: 480)

        Window("Report an Issue", id: "feedback") {
            FeedbackView()
                .environment(model)
        }
        .windowResizability(.contentSize)

        Settings {
            SettingsView()
                .environment(model)
        }
    }
}
