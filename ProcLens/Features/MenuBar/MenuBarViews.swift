import SwiftUI
import AppKit
import Observation
import ProcLensCore

/// Template bitmap of recent CPU history as bars (+ optional percentage), assigned straight to the status item
/// button (no SwiftUI label involved). Rendered into a bitmap, not a drawing-handler image, so AppKit does not
/// re-run drawing code for every status-item replicant refresh.
@MainActor
enum MenuBarGraph {
    static let barCount = 24
    private static let barW: CGFloat = 2, gap: CGFloat = 1, h: CGFloat = 16
    private static let scale: CGFloat = 2
    private static let font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
    private static let attrs: [NSAttributedString.Key: Any] = [.font: font]
    static let graphWidth = CGFloat(barCount) * (barW + gap)
    /// Room for the widest value ("100%"), so the item keeps one length and is never re-laid out per tick.
    static let textWidth: CGFloat = ceil(("100%" as NSString).size(withAttributes: attrs).width) + 4

    static func width(showsPercent: Bool) -> CGFloat { graphWidth + (showsPercent ? textWidth : 0) }

    /// Quantized bar heights (pixels of a 16 pt graph); equal heights + text => identical image.
    static func heights(_ cpu: [Double]) -> [Int] {
        cpu.suffix(barCount).map { max(1, Int((min(1, max(0, $0)) * h).rounded())) }
    }

    static func image(heights: [Int], text: String?, color: NSColor) -> NSImage {
        let size = NSSize(width: width(showsPercent: text != nil), height: h)
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: Int(size.width * scale), pixelsHigh: Int(size.height * scale),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let ctx = NSGraphicsContext(bitmapImageRep: rep) else {
            return NSImage(size: size)
        }
        rep.size = size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = ctx
        color.setFill()
        let pad = barCount - heights.count
        for (i, bh) in heights.enumerated() {
            NSRect(x: CGFloat(pad + i) * (barW + gap), y: 0, width: barW, height: CGFloat(bh)).fill()
        }
        if let text {
            let s = (text as NSString).size(withAttributes: attrs)
            (text as NSString).draw(at: NSPoint(x: graphWidth + textWidth - s.width, y: (h - s.height) / 2),
                                    withAttributes: [.font: font, .foregroundColor: color])
        }
        NSGraphicsContext.restoreGraphicsState()
        let image = NSImage(size: size)
        image.addRepresentation(rep)
        return image
    }
}

/// Owns the status item and the popover that hosts the quick panel (replaces `MenuBarExtra`, whose label had to
/// be re-rendered as a new image on every tick).
@MainActor
final class StatusItemController: NSObject, NSPopoverDelegate {
    private let model: AppModel
    private let actions: ProcessActionCenter
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private var lastKey: ([Int], String?)?
    private var lastDraw: CFTimeInterval = 0
    private static let minRedrawGap: CFTimeInterval = 1.5
    private let popover = NSPopover()
    private var showsPercent = UserDefaults.standard.object(forKey: "menuBarShowsPercent") as? Bool ?? true
    private var defaultsObserver: NSObjectProtocol?
    private var appearanceObserver: NSKeyValueObservation?

    init(model: AppModel, actions: ProcessActionCenter) {
        self.model = model
        self.actions = actions
        super.init()
        popover.behavior = .transient
        popover.animates = false
        popover.delegate = self
        if let button = item.button {
            button.target = self
            button.action = #selector(toggle(_:))
            button.setAccessibilityLabel("ProcLens CPU")
            button.imagePosition = .imageOnly
            // The bitmap is pre-tinted (cheaper to draw than a template), so redraw when light/dark changes.
            appearanceObserver = button.observe(\.effectiveAppearance) { [weak self] _, _ in
                MainActor.assumeIsolated { self?.lastKey = nil; self?.lastDraw = 0; self?.refresh() }
            }
        }
        applyWidth()
        defaultsObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let v = UserDefaults.standard.object(forKey: "menuBarShowsPercent") as? Bool ?? true
                if v != self.showsPercent { self.showsPercent = v; self.applyWidth(); self.refresh() }
            }
        }
        refresh()
        track()
    }

    private func applyWidth() {
        item.length = MenuBarGraph.width(showsPercent: showsPercent) + 8
        lastKey = nil
    }

    private func refresh() {
        // At most one redraw per `minRedrawGap`: every status-item image change makes AppKit re-render the item
        // (and its replicants), which cost more than the whole sampler. The bars then advance two samples at a time.
        let now = CACurrentMediaTime()
        if lastKey != nil, now - lastDraw < Self.minRedrawGap { return }
        let values = model.history.suffix(MenuBarGraph.barCount).map { $0.cpu?.total ?? 0 }
        let heights = MenuBarGraph.heights(values)
        let text = showsPercent ? Format.percent(values.last ?? 0) : nil
        if let k = lastKey, k.0 == heights, k.1 == text { return }
        lastKey = (heights, text)
        lastDraw = now
        var color = NSColor.black
        (item.button?.effectiveAppearance ?? NSApp.effectiveAppearance).performAsCurrentDrawingAppearance {
            color = NSColor.labelColor.usingColorSpace(.deviceRGB) ?? .black
        }
        item.button?.image = MenuBarGraph.image(heights: heights, text: text, color: color)
        item.button?.setAccessibilityValue(Format.percent(values.last ?? 0))
    }

    /// Re-arming observation: one callback per tick, no SwiftUI involved.
    private func track() {
        withObservationTracking {
            _ = model.latest?.instant
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.refresh()
                self?.track()
            }
        }
    }

    @objc private func toggle(_ sender: NSStatusBarButton) {
        if popover.isShown { popover.performClose(sender); return }
        let content = MenuBarContent()
            .environment(model)
            .environment(actions)
            .processActionConfirmation(actions)
        let host = NSHostingController(rootView: content)
        host.sizingOptions = [.preferredContentSize]
        popover.contentViewController = host
        popover.show(relativeTo: sender.bounds, of: sender, preferredEdge: .minY)
        sender.highlight(true)
        popover.contentViewController?.view.window?.makeKey()
    }

    func popoverDidClose(_ notification: Notification) {
        item.button?.highlight(false)
        popover.contentViewController = nil  // frees the panel view tree while closed
        model.setPanelOpen(false)
    }
}

/// Lets AppKit-hosted UI (the popover) open the SwiftUI main window.
@MainActor
enum WindowOpener {
    static var openMain: (() -> Void)?

    static func showMainWindow() {
        NSApplication.shared.activate(ignoringOtherApps: true)
        if let w = NSApp.windows.first(where: { $0.canBecomeMain && !($0 is NSPanel) }) {
            if w.isMiniaturized { w.deminiaturize(nil) }
            w.makeKeyAndOrderFront(nil)
        } else {
            openMain?()
        }
    }

    static func showSettings() {
        NSApplication.shared.activate(ignoringOtherApps: true)
        NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
    }
}
