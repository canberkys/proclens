import ProcLensCore
import SwiftUI

/// Closures the main window publishes so menu commands can drive its sheets and sidebar.
struct WindowActions {
    var showEndByPID: () -> Void
    var showAbout: () -> Void
    var select: (SidebarItem) -> Void
}

extension FocusedValues {
    @Entry var windowActions: WindowActions?
    /// Rows selected in the visible process table (Processes or Details).
    @Entry var selectedProcessIDs: [ProcessID]?
}

/// Main menu bar. Add with `.commands { ProcLensCommands(model:actions:) }` on the main `Window` scene.
struct ProcLensCommands: Commands {
    let model: AppModel
    let actions: ProcessActionCenter

    @FocusedValue(\.windowActions) private var window
    @FocusedValue(\.selectedProcessIDs) private var selected
    @Environment(\.openWindow) private var openWindow
    private var updater: UpdaterController { .shared }

    private var ids: [ProcessID] { selected ?? [] }
    private var noSelection: Bool { ids.isEmpty }

    var body: some Commands {
        // ProcLens menu: About, Check for Updates…; Settings…, Services, Hide and Quit are provided by the system.
        CommandGroup(replacing: .appInfo) {
            Button("About ProcLens") { window?.showAbout() }
                .disabled(window == nil)
            Button("Check for Updates…") { updater.checkForUpdates() }
                .disabled(!updater.canCheckForUpdates)
        }

        SidebarCommands()
        CommandGroup(before: .sidebar) {
            ForEach(Array(SidebarItem.allCases.enumerated()), id: \.element) { index, item in
                Button(item.rawValue) { window?.select(item) }
                    .keyboardShortcut(KeyEquivalent(Character(String(index + 1))), modifiers: .command)
                    .disabled(window == nil)
            }
            Divider()
            Menu("Update Speed") {
                Picker("Update Speed", selection: Binding(get: { model.interval }, set: { model.setInterval($0) })) {
                    ForEach(SamplingInterval.allCases, id: \.self) { i in
                        Text("\(i.rawValue.formatted()) s").tag(i)
                    }
                }
                .pickerStyle(.inline)
                .labelsHidden()
            }
            Divider()
        }

        CommandMenu("Process") {
            Button("End Task") { actions.request(.quit, on: ids) }
                // Delete is handled by the tables themselves; binding a bare ⌫ here would also eat it in text fields.
                .disabled(noSelection)
            Button("Force Quit") { actions.request(.forceQuit, on: ids) }
                .keyboardShortcut(.delete, modifiers: .option)
                .disabled(noSelection)
            Button("End Process Tree…") { actions.request(.endTree, on: ids) }
                .disabled(ids.count != 1)
            Divider()
            Button("Suspend") { actions.request(.suspend, on: ids) }
                .disabled(noSelection)
            Button("Resume") { actions.request(.resume, on: ids) }
                .disabled(noSelection)
            Divider()
            Button("Properties…") { actions.request(.properties, on: ids) }
                .keyboardShortcut("i", modifiers: .command)
                .disabled(noSelection)
            Button("End Process by PID…") { window?.showEndByPID() }
                .keyboardShortcut("k", modifiers: .command)
                .disabled(window == nil)
            Divider()
            Button("Reveal in Finder") { actions.request(.revealInFinder, on: ids) }
                .disabled(noSelection)
            Button("Copy PID") { actions.request(.copyPID, on: ids) }
                .disabled(noSelection)
            Button("Copy Path") { actions.request(.copyPath, on: ids) }
                .disabled(noSelection)
        }

        CommandGroup(replacing: .help) {
            Button("ProcLens Help") { open("help") }
                .keyboardShortcut("/", modifiers: [.command, .shift])
            Button("Keyboard Shortcuts") { open("help", topic: "shortcuts") }
            Button("proclens Command-Line Tool") { open("help", topic: "cli") }
            Divider()
            Button("Release Notes") { open("releasenotes") }
            Button("Report an Issue…") { open("feedback") }
        }
    }

    private func open(_ id: String, topic: String? = nil) {
        if let topic { UserDefaults.standard.set(topic, forKey: HelpNavigation.topicKey) }
        openWindow(id: id)
        NSApp.activate(ignoringOtherApps: true)
    }
}

/// Lets menu items jump straight to a help topic (the Help window reads and clears this on appear / change).
enum HelpNavigation {
    static let topicKey = "helpPendingTopic"
}
