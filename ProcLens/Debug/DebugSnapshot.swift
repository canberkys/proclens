#if DEBUG
import AppKit
import SwiftUI

/// Debug-only verification hooks driven by launch arguments:
///   -ProcLensTab <processes|performance|details>   initial sidebar selection
///   -ProcLensSnapshot <path.png>                    render the main window to PNG after a few ticks, then quit
///   -ProcLensSnapshotDelay <seconds>                wait before rendering (default 5)
/// Renders via `cacheDisplay`, so no Screen Recording permission is needed.
enum DebugSnapshot {
    static var initialTab: SidebarItem? {
        UserDefaults.standard.string(forKey: "ProcLensTab").flatMap { raw in
            SidebarItem.allCases.first { $0.rawValue.lowercased().hasPrefix(raw.lowercased()) }
        }
    }

    /// Called from `App.init`, so it works even when macOS never creates the main window
    /// (screen locked or asleep). Falls back to hosting `ContentView` offscreen.
    @MainActor
    static func scheduleIfRequested(model: AppModel, actions: ProcessActionCenter) {
        guard let path = UserDefaults.standard.string(forKey: "ProcLensSnapshot") else { return }
        let delay = UserDefaults.standard.double(forKey: "ProcLensSnapshotDelay")
        Task { @MainActor in
            // Give the real window a moment to appear; otherwise host the UI offscreen.
            try? await Task.sleep(for: .seconds(1))
            let real = NSApp.windows.first { $0.isVisible && $0.canBecomeMain && $0.frame.width > 400 }
            var offscreen: NSWindow?
            if real == nil {
                let host = NSHostingView(rootView: ContentView()
                    .environment(model).environment(actions)
                    .frame(width: 1200, height: 800))
                let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1200, height: 800),
                                      styleMask: [.titled, .fullSizeContentView], backing: .buffered, defer: false)
                window.contentView = host
                window.alphaValue = 0.01
                window.orderFrontRegardless()
                offscreen = window
            }
            try? await Task.sleep(for: .seconds(delay > 0 ? delay : 5))
            guard let window = real ?? offscreen,
                  let view = window.contentView?.superview ?? window.contentView,
                  let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { exit(2) }
            view.cacheDisplay(in: view.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
            exit(0)
        }
    }
}
#endif
