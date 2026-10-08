import AppKit
import SwiftUI

/// Registers the global hotkey from inside a view, where `openWindow` is available.
private struct HotKeyBridge: ViewModifier {
    @Environment(\.openWindow) private var openWindow

    func body(content: Content) -> some View {
        content.task {
            HotKeyController.shared.start {
                openWindow(id: "main")
                NSApp.activate(ignoringOtherApps: true)
            }
        }
    }
}

extension View {
    func globalHotKey() -> some View { modifier(HotKeyBridge()) }
}
