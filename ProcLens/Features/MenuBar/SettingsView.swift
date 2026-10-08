import SwiftUI
import AppKit
import ProcLensCore

enum AppPresentation {
    /// Dock icon on (default) → .regular, off → .accessory. Call once at launch.
    @MainActor static func applyStoredActivationPolicy() {
        let show = UserDefaults.standard.object(forKey: "showDockIcon") as? Bool ?? true
        NSApplication.shared.setActivationPolicy(show ? .regular : .accessory)
    }
}

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @AppStorage(MenuBarStyle.defaultsKey) private var menuBarStyle = MenuBarStyle.icon.rawValue
    @AppStorage("showDockIcon") private var showDock = true

    var body: some View {
        Form {
            Picker("Sampling interval", selection: Binding(get: { model.interval }, set: { model.setInterval($0) })) {
                ForEach(SamplingInterval.allCases, id: \.self) { i in
                    Text("\(i.rawValue.formatted()) s").tag(i)
                }
            }
            Picker("Menu bar shows", selection: $menuBarStyle) {
                ForEach(MenuBarStyle.allCases) { Text($0.title).tag($0.rawValue) }
            }
            Toggle("Show Dock icon", isOn: $showDock)
                .onChange(of: showDock) { _, _ in AppPresentation.applyStoredActivationPolicy() }
            LabeledContent("Open ProcLens shortcut") { HotKeyRecorder() }
            HelperSection()
            UpdatesSection()
        }
        .formStyle(.grouped)
        .frame(width: 400)
        .fixedSize(horizontal: false, vertical: true)
    }
}

/// Click, press a combination with at least one of ⌘ ⌥ ⌃; Esc cancels.
private struct HotKeyRecorder: View {
    @State private var recording = false
    @State private var monitor: Any?
    @State private var label = HotKeyController.storedCode < 0 ? "None" : HotKeyController.storedLabel

    var body: some View {
        HStack {
            Button(recording ? "Press shortcut…" : label) { recording ? stop() : start() }
                .frame(minWidth: 120)
            Button("Reset") {
                stop()
                HotKeyController.shared.set(code: HotKeyController.defaultCode, mods: HotKeyController.defaultMods,
                                            label: HotKeyController.display(mods: HotKeyController.defaultMods, key: "P"))
                label = HotKeyController.storedLabel
            }
        }
        .onDisappear { stop() }
    }

    private func start() {
        recording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { e in
            if e.keyCode == 53 { stop(); return nil }
            let mods = e.modifierFlags.intersection(.deviceIndependentFlagsMask).carbonMask
            guard e.modifierFlags.contains(.command) || e.modifierFlags.contains(.option) || e.modifierFlags.contains(.control) else {
                NSSound.beep(); return nil
            }
            let names: [UInt16: String] = [49: "Space", 36: "Return", 48: "Tab", 51: "Delete"]
            var key = names[e.keyCode] ?? (e.charactersIgnoringModifiers ?? "").uppercased()
            if key.unicodeScalars.first.map({ $0.value >= 0xF700 }) ?? true { key = "Key \(e.keyCode)" }
            let text = HotKeyController.display(mods: mods, key: key)
            HotKeyController.shared.set(code: Int(e.keyCode), mods: mods, label: text)
            label = text
            stop()
            return nil
        }
    }

    private func stop() {
        recording = false
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }
}
