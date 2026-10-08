#if DEBUG
import AppKit
import SwiftUI

/// `-ProcLensPanelSnapshot <path.png>`: hosts the quick panel offscreen with a live model for ~6 s, writes a PNG, exits.
enum PanelSnapshot {
    @MainActor
    static func scheduleIfRequested() {
        // -ProcLensMenuBarSnapshot <png>: menu bar item variants on light and dark strips, at 2x.
        if let out = UserDefaults.standard.string(forKey: "ProcLensMenuBarSnapshot") {
            let cpu: [Double] = [0.05, 0.12, 0.08, 0.35, 0.22, 0.18, 0.20]
            let h = MenuBarGraph.heights(cpu)
            let canvas = NSImage(size: NSSize(width: 900, height: 180), flipped: false) { _ in
                NSGraphicsContext.current?.cgContext.scaleBy(x: 3, y: 3)
                for (row, (bg, fg)) in [(NSColor(white: 0.93, alpha: 1), NSColor.black), (NSColor(white: 0.16, alpha: 1), NSColor.white)].enumerated() {
                    bg.setFill(); NSRect(x: 0, y: CGFloat(row) * 30, width: 300, height: 30).fill()
                    var x: CGFloat = 10
                    for style in MenuBarStyle.allCases {
                        let img = MenuBarGraph.image(style: style, heights: h, text: "24%", color: fg)
                        img.draw(in: NSRect(x: x, y: CGFloat(row) * 30 + 7, width: img.size.width, height: img.size.height))
                        x += img.size.width + 30
                    }
                }
                return true
            }
            let rep = NSBitmapImageRep(data: canvas.tiffRepresentation!)!
            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: out))
            exit(0)
        }
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
