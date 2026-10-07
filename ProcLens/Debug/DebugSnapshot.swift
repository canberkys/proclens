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

    @MainActor
    static func scheduleIfRequested() {
        guard let path = UserDefaults.standard.string(forKey: "ProcLensSnapshot") else { return }
        Task { @MainActor in
            let delay = UserDefaults.standard.double(forKey: "ProcLensSnapshotDelay")
            try? await Task.sleep(for: .seconds(delay > 0 ? delay : 5))
            guard let window = NSApp.windows.first(where: { $0.isVisible && $0.contentView != nil && $0.frame.width > 400 }),
                  let view = window.contentView?.superview ?? window.contentView,
                  let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { exit(2) }
            view.cacheDisplay(in: view.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
            NSApp.terminate(nil)
        }
    }
}
#endif
