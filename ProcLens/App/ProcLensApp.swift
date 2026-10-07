import SwiftUI

@main
struct ProcLensApp: App {
    var body: some Scene {
        Window("ProcLens", id: "main") {
            ContentView()
                .frame(minWidth: 900, minHeight: 600)
        }

        MenuBarExtra("ProcLens", systemImage: "gauge.with.dots.needle.33percent") {
            Text("ProcLens")
            Divider()
            Button("Quit") { NSApplication.shared.terminate(nil) }
                .keyboardShortcut("q")
        }

        Settings {
            Text("Settings will appear here.")
                .padding(40)
        }
    }
}
