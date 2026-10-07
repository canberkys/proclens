import SwiftUI
import AppKit
import ProcLensCore

/// Template NSImage with recent CPU history as bars (+ optional percentage).
@MainActor
enum MenuBarGraph {
    static let barCount = 24
    private static let barW: CGFloat = 2, gap: CGFloat = 1, h: CGFloat = 16
    private static let scale: CGFloat = 2
    private static let font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
    private static let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.black]
    private static var cached: (key: [Int], text: String, image: NSImage)?

    /// Rendered once into a bitmap (not a drawing-handler image, which AppKit re-runs for every redraw of the
    /// status item) and reused while the quantized bar heights and the percentage text are unchanged.
    static func image(cpu: [Double], showPercent: Bool) -> NSImage {
        let samples = Array(cpu.suffix(barCount))
        let heights = samples.map { max(1, Int((min(1, max(0, $0)) * h).rounded())) }
        let text = showPercent ? Format.percent(cpu.last ?? 0) : ""
        let key = heights + [showPercent ? 1 : 0]
        if let c = cached, c.key == key, c.text == text { return c.image }

        let graphW = CGFloat(barCount) * (barW + gap)
        let textW = showPercent ? ceil((text as NSString).size(withAttributes: attrs).width) + 4 : 0
        let size = NSSize(width: graphW + textW, height: h)
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
        NSColor.black.setFill()
        let pad = barCount - heights.count
        for (i, bh) in heights.enumerated() {
            NSRect(x: CGFloat(pad + i) * (barW + gap), y: 0, width: barW, height: CGFloat(bh)).fill()
        }
        if showPercent {
            let s = (text as NSString).size(withAttributes: attrs)
            (text as NSString).draw(at: NSPoint(x: graphW + 4, y: (h - s.height) / 2), withAttributes: attrs)
        }
        NSGraphicsContext.restoreGraphicsState()
        let image = NSImage(size: size)
        image.addRepresentation(rep)
        image.isTemplate = true
        cached = (key, text, image)
        return image
    }
}

struct MenuBarLabel: View {
    let model: AppModel
    @AppStorage("menuBarShowsPercent") private var showPercent = true

    var body: some View {
        let values = model.history.suffix(MenuBarGraph.barCount).map { $0.cpu?.total ?? 0 }
        Image(nsImage: MenuBarGraph.image(cpu: values, showPercent: showPercent))
            .accessibilityLabel("ProcLens CPU \(Format.percent(values.last ?? 0))")
    }
}
