import AppKit
import ProcLensCore
import SwiftUI

/// One window per inspected process; opening the same process again fronts the existing window.
@MainActor
final class InspectorWindows: NSObject, NSWindowDelegate {
    static let shared = InspectorWindows()
    private var windows: [ProcessID: NSWindow] = [:]

    func show(_ p: ProcessSample, model: AppModel, actions: ProcessActionCenter) {
        if let w = windows[p.id] {
            w.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let inspector = InspectorModel(sample: p, app: model)
        let host = NSHostingController(rootView: InspectorView(model: inspector).environment(actions))
        let w = NSWindow(contentViewController: host)
        w.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        w.title = "\(p.name) — PID \(p.pid)"
        w.setContentSize(NSSize(width: 780, height: 540))
        w.contentMinSize = NSSize(width: 560, height: 380)
        w.isReleasedWhenClosed = false
        w.isRestorable = false
        w.delegate = self
        w.center()
        if !windows.isEmpty {
            let o = CGFloat(windows.count % 8) * 24
            w.setFrameOrigin(NSPoint(x: w.frame.origin.x + o, y: w.frame.origin.y - o))
        }
        windows[p.id] = w
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowWillClose(_ notification: Notification) {
        guard let w = notification.object as? NSWindow else { return }
        windows = windows.filter { $0.value !== w }
    }

    #if DEBUG
    func snapshot(of id: ProcessID, to path: String) {
        guard let view = windows[id]?.contentView?.superview ?? windows[id]?.contentView,
              let rep = DebugSnapshot.snapshotRep(of: view) else { return }
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
    }
    #endif
}
