import SwiftUI
import AppKit
import Observation
import ProcLensCore

/// What the status item shows. Default `.icon`: CPU glyph + percentage (self-explanatory, ~50 pt).
enum MenuBarStyle: String, CaseIterable, Identifiable {
    case icon, percent, graph
    var id: String { rawValue }
    var title: String {
        switch self {
        case .icon: "CPU icon and percentage"
        case .percent: "Percentage only"
        case .graph: "Percentage and graph"
        }
    }
    static let defaultsKey = "menuBarStyle"
    static var stored: MenuBarStyle {
        UserDefaults.standard.string(forKey: defaultsKey).flatMap(MenuBarStyle.init) ?? .icon
    }
}

/// Status item image, rendered into a bitmap and assigned straight to the button (no SwiftUI label),
/// so AppKit does not re-run drawing code for every status-item replicant refresh.
@MainActor
enum MenuBarGraph {
    static let barCount = 7
    private static let barW: CGFloat = 4, gap: CGFloat = 1, h: CGFloat = 16, spacing: CGFloat = 4
    private static let scale: CGFloat = 2
    private static let font = NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .medium)
    private static let attrs: [NSAttributedString.Key: Any] = [.font: font]
    private static let iconSize: CGFloat = 15
    static let graphWidth = CGFloat(barCount) * (barW + gap) - gap
    /// Room for the widest value ("100%"), so the item keeps one length and is never re-laid out per tick.
    static let textWidth: CGFloat = ceil(("100%" as NSString).size(withAttributes: attrs).width)

    static func width(_ style: MenuBarStyle) -> CGFloat {
        switch style {
        case .icon: iconSize + spacing + textWidth
        case .percent: textWidth
        case .graph: textWidth + spacing + graphWidth
        }
    }

    /// Quantized bar heights in half points of a 16 pt graph; equal heights + text => identical image.
    static func heights(_ cpu: [Double]) -> [Int] {
        cpu.suffix(barCount).map { Int((min(1, max(0, $0)) * h * 2).rounded()) }
    }

    private static func cpuGlyph(color: NSColor) -> NSImage? {
        let config = NSImage.SymbolConfiguration(pointSize: iconSize - 1, weight: .medium)
            .applying(.init(paletteColors: [color]))
        return NSImage(systemSymbolName: "cpu", accessibilityDescription: "CPU")?.withSymbolConfiguration(config)
    }

    static func image(style: MenuBarStyle, heights: [Int], text: String, color: NSColor) -> NSImage {
        let size = NSSize(width: width(style), height: h)
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
        var x: CGFloat = 0
        if style == .icon, let glyph = cpuGlyph(color: color) {
            let g = glyph.size
            glyph.draw(in: NSRect(x: (iconSize - g.width) / 2, y: (h - g.height) / 2, width: g.width, height: g.height))
            x = iconSize + spacing
        }
        let s = (text as NSString).size(withAttributes: attrs)
        // Left-aligned next to the icon (no gap that grows with short values); right-aligned otherwise.
        let tx = style == .icon ? x : x + textWidth - s.width
        (text as NSString).draw(at: NSPoint(x: tx, y: (h - s.height) / 2), withAttributes: [.font: font, .foregroundColor: color])
        if style == .graph {
            let gx = textWidth + spacing
            let pad = barCount - heights.count
            for i in 0..<barCount {
                let bx = gx + CGFloat(i) * (barW + gap)
                color.withAlphaComponent(0.3).setFill()
                NSBezierPath(roundedRect: NSRect(x: bx, y: 1, width: barW, height: h - 2), xRadius: 1, yRadius: 1).fill()
                guard i >= pad else { continue }
                let bh = max(2, min(h - 2, CGFloat(heights[i - pad]) / 2))
                color.setFill()
                NSBezierPath(roundedRect: NSRect(x: bx, y: 1, width: barW, height: bh), xRadius: 1, yRadius: 1).fill()
            }
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
    private var style = MenuBarStyle.stored
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
            button.imageScaling = .scaleNone  // never shrink to fit; the item sizes to its content
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
                let st = MenuBarStyle.stored
                if st != self.style { self.style = st; self.applyWidth(); self.refresh() }
            }
        }
        refresh()
        track()
    }

    /// Text styles use the button's own title + a template SF Symbol (native look, exact content width,
    /// automatic light/dark/highlight). Only the graph style draws a bitmap.
    private static let titleFont = NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
    private static let cpuSymbol: NSImage? = {
        let image = NSImage(systemSymbolName: "cpu", accessibilityDescription: "CPU")?
            .withSymbolConfiguration(.init(pointSize: NSFont.systemFontSize, weight: .regular))
        image?.isTemplate = true
        return image
    }()

    private func applyWidth() {
        item.length = NSStatusItem.variableLength
        guard let button = item.button else { return }
        switch style {
        case .icon: button.image = Self.cpuSymbol; button.imagePosition = .imageLeading
        case .percent: button.image = nil; button.imagePosition = .noImage
        case .graph: button.title = ""; button.imagePosition = .imageOnly
        }
        lastKey = nil
    }

    /// "  7%" / " 42%" / "100%" with figure spaces, so the width stays constant as the value changes.
    private static func paddedPercent(_ fraction: Double) -> String {
        let v = Int((min(1, max(0, fraction)) * 100).rounded())
        let digits = String(v)
        return String(repeating: "\u{2007}", count: max(0, 3 - digits.count)) + digits + "%"
    }

    private func refresh() {
        // At most one redraw per `minRedrawGap`: every status-item image change makes AppKit re-render the item
        // (and its replicants), which cost more than the whole sampler. The bars then advance two samples at a time.
        let now = CACurrentMediaTime()
        if lastKey != nil, now - lastDraw < Self.minRedrawGap { return }
        let values = model.history.suffix(MenuBarGraph.barCount).map { $0.cpu?.total ?? 0 }
        let heights = style == .graph ? MenuBarGraph.heights(values) : []  // text-only styles redraw only when the % changes
        let text = Format.percent(values.last ?? 0)
        if let k = lastKey, k.0 == heights, k.1 == text { return }
        lastKey = (heights, text)
        lastDraw = now
        if style == .graph {
            var color = NSColor.black
            (item.button?.effectiveAppearance ?? NSApp.effectiveAppearance).performAsCurrentDrawingAppearance {
                color = NSColor.labelColor.usingColorSpace(.deviceRGB) ?? .black
            }
            item.button?.image = MenuBarGraph.image(style: .graph, heights: heights, text: text, color: color)
        } else {
            item.button?.attributedTitle = NSAttributedString(
                string: Self.paddedPercent(values.last ?? 0), attributes: [.font: Self.titleFont])
        }
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
