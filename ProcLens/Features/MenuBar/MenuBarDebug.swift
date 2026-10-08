#if DEBUG
import AppKit
import SwiftUI

/// `-ProcLensPanelSnapshot <path.png>`: hosts the quick panel offscreen with a live model for ~6 s, writes a PNG, exits.
enum PanelSnapshot {
    @MainActor
    static func scheduleIfRequested() {
        guard let path = UserDefaults.standard.string(forKey: "ProcLensPanelSnapshot") else { return }
        let model = AppModel()
        let actions = ProcessActionCenter(model: model)
        model.start()
        let host = NSHostingView(rootView: MenuBarContent().environment(model).environment(actions).background(Color(nsColor: .windowBackgroundColor)))
        host.appearance = NSAppearance(named: .aqua)
        let window = NSWindow(contentRect: NSRect(x: 200, y: 200, width: 340, height: 480),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        window.alphaValue = 0.01; window.orderFrontRegardless()
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(6))
            host.layoutSubtreeIfNeeded()
            let size = host.fittingSize
            window.setContentSize(size)
            host.frame = NSRect(origin: .zero, size: size)
            host.layoutSubtreeIfNeeded()
            guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { exit(2) }
            host.cacheDisplay(in: host.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
            exit(0)
        }
    }
}
#endif
