#if DEBUG
import AppKit
import SwiftUI

/// Debug-only verification hooks driven by launch arguments:
///   -ProcLensTab <processes|performance|details>   initial sidebar selection
///   -ProcLensSnapshot <path.png>                    render the main window to PNG after a few ticks, then quit
///   -ProcLensSnapshotDelay <seconds>                wait before rendering (default 5)
///   -ProcLensSnapshotLayers 1 [-ProcLensSnapshotScale 2] [-ProcLensSnapshotCropLeft <pt>]
///                                                   render through CALayers at 2x; use CropLeft to trim the sidebar if wanted
///   -ProcLensSnapshotWidth/-Height <pt>             offscreen window size (default 1200x800)
/// Renders via `cacheDisplay`, so no Screen Recording permission is needed.
extension View {
    /// Snapshot runs only: the sidebar's vibrancy view renders blank offscreen, so paint an opaque sidebar gray instead.
    @ViewBuilder
    func debugSnapshotSidebarBackground() -> some View {
        if UserDefaults.standard.string(forKey: "ProcLensSnapshot") != nil {
            self.scrollContentBackground(.hidden)
                .background(Color(red: 0.925, green: 0.929, blue: 0.941))
        } else {
            self
        }
    }
}

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
                let d = UserDefaults.standard
                let w = d.double(forKey: "ProcLensSnapshotWidth") > 0 ? d.double(forKey: "ProcLensSnapshotWidth") : 1200
                let h = d.double(forKey: "ProcLensSnapshotHeight") > 0 ? d.double(forKey: "ProcLensSnapshotHeight") : 800
                let host = NSHostingView(rootView: ContentView()
                    .environment(model).environment(actions)
                    .frame(width: w, height: h))
                let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: w, height: h),
                                      styleMask: [.titled, .fullSizeContentView], backing: .buffered, defer: false)
                window.contentView = host
                window.alphaValue = 0.01
                window.orderFrontRegardless()
                offscreen = window
            }
            try? await Task.sleep(for: .seconds(delay > 0 ? delay : 5))
            guard let window = real ?? offscreen,
                  let view = window.contentView?.superview ?? window.contentView,
                  let rep = Self.snapshotRep(of: view) else { exit(2) }
            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
            exit(0)
        }
    }

    @MainActor
    static func snapshotRep(of view: NSView) -> NSBitmapImageRep? {
        if UserDefaults.standard.bool(forKey: "ProcLensSnapshotLayers") {
            let scale = CGFloat(max(1, UserDefaults.standard.double(forKey: "ProcLensSnapshotScale")))
            return renderLayers(of: view, scale: scale)
        }
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return nil }
        view.cacheDisplay(in: view.bounds, to: rep)
        return rep
    }

    /// The sidebar's outline rows are not captured by layer rendering; paint an opaque sidebar gray, the selection pill
    /// and each cell (via `cacheDisplay`) on top.
    @MainActor
    private static func paintSidebar(in root: NSView, context: CGContext) {
        func find(_ v: NSView, _ name: String) -> NSView? {
            if String(describing: type(of: v)).contains(name) { return v }
            return v.subviews.lazy.compactMap { find($0, name) }.first
        }
        func all(_ v: NSView, _ name: String, _ out: inout [NSView]) {
            if String(describing: type(of: v)).contains(name) { out.append(v) }
            v.subviews.forEach { all($0, name, &out) }
        }
        guard let side = find(root, "OutlineListRepresentable") else { return }
        context.saveGState()
        context.setFillColor(CGColor(red: 0.925, green: 0.929, blue: 0.941, alpha: 1))
        context.fill(root.convert(side.bounds, from: side))
        var rows: [NSView] = []
        all(side, "ListTableRowView", &rows)
        for row in rows {
            if let pill = row.subviews.first(where: { $0 is NSVisualEffectView }) {
                let r = root.convert(pill.bounds, from: pill)
                context.setFillColor(NSColor.controlAccentColor.withAlphaComponent(0.22).cgColor)
                context.addPath(CGPath(roundedRect: r, cornerWidth: 6, cornerHeight: 6, transform: nil))
                context.fillPath()
            }
        }
        var cells: [NSView] = []
        all(side, "CellHostingView", &cells)
        for cell in cells {
            guard let rep = cell.bitmapImageRepForCachingDisplay(in: cell.bounds) else { continue }
            cell.cacheDisplay(in: cell.bounds, to: rep)
            guard let image = rep.cgImage else { continue }
            let r = root.convert(cell.bounds, from: cell)
            context.saveGState()
            if root.isFlipped { context.translateBy(x: 0, y: r.minY + r.maxY); context.scaleBy(x: 1, y: -1) }
            context.draw(image, in: r)
            context.restoreGState()
        }
        context.restoreGState()
    }

    /// Renders `view` through its Core Animation layer at `scale`x. Unlike `cacheDisplay` this includes content that
    /// only exists in layers (the sidebar list and its material), which `cacheDisplay` leaves blank offscreen.
    @MainActor
    static func renderLayers(of view: NSView, scale: CGFloat) -> NSBitmapImageRep? {
        view.layoutSubtreeIfNeeded()
        if UserDefaults.standard.bool(forKey: "ProcLensDumpViews") {
            func dump(_ v: NSView, _ d: Int) {
                print(String(repeating: " ", count: d), type(of: v), v.frame, v.wantsLayer, v.isHidden)
                v.subviews.forEach { dump($0, d + 1) }
            }
            dump(view, 0); fflush(stdout)
        }
        let crop = CGFloat(UserDefaults.standard.double(forKey: "ProcLensSnapshotCropLeft")) * scale
        let width = Int(view.bounds.width * scale), height = Int(view.bounds.height * scale)
        guard width > 0, height > 0, let layer = view.layer,
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue) else { return nil }
        context.scaleBy(x: scale, y: scale)
        if view.isFlipped {  // a flipped root (plain NSHostingView) renders upside down otherwise
            context.translateBy(x: 0, y: view.bounds.height)
            context.scaleBy(x: 1, y: -1)
        }
        layer.render(in: context)
        paintSidebar(in: view, context: context)
        guard let full = context.makeImage(),
              let cropped = crop > 0 ? full.cropping(to: CGRect(x: crop, y: 0, width: CGFloat(width) - crop, height: CGFloat(height))) : full
        else { return nil }
        return NSBitmapImageRep(cgImage: cropped)
    }
}
#endif
