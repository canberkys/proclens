// ProcLens app icon generator. Usage: swift make_icon.swift <outDir>
// Writes: <outDir>/master.png (1024, no label), <outDir>/alt.png (1024, with PROC label),
//         <outDir>/AppIcon/icon_*.png (macOS appiconset sizes) and <outDir>/preview.png.
// CoreGraphics + AppKit only; every size is rendered from vectors.
import AppKit
import CoreGraphics

func rgb(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 255) / 255, green: CGFloat((hex >> 8) & 255) / 255,
            blue: CGFloat(hex & 255) / 255, alpha: a)
}
let cs = CGColorSpace(name: CGColorSpace.sRGB)!

func gradient(_ colors: [CGColor], _ locs: [CGFloat]? = nil) -> CGGradient {
    CGGradient(colorsSpace: cs, colors: colors as CFArray, locations: locs)!
}

func squircle(_ r: CGRect, n: Double = 4.0) -> CGPath {
    let p = CGMutablePath()
    let a = r.width / 2, b = r.height / 2, steps = 720
    for i in 0...steps {
        let t = Double(i) / Double(steps) * 2 * .pi
        let c = cos(t), s = sin(t)
        let x = r.midX + a * CGFloat(copysign(pow(abs(c), 2 / n), c))
        let y = r.midY + b * CGFloat(copysign(pow(abs(s), 2 / n), s))
        i == 0 ? p.move(to: CGPoint(x: x, y: y)) : p.addLine(to: CGPoint(x: x, y: y))
    }
    p.closeSubpath()
    return p
}

func smoothPath(_ pts: [CGPoint]) -> CGPath {
    let p = CGMutablePath()
    p.move(to: pts[0])
    for i in 0..<pts.count - 1 {
        let p0 = pts[max(i - 1, 0)], p1 = pts[i], p2 = pts[i + 1], p3 = pts[min(i + 2, pts.count - 1)]
        let c1 = CGPoint(x: p1.x + (p2.x - p0.x) / 6, y: p1.y + (p2.y - p0.y) / 6)
        let c2 = CGPoint(x: p2.x - (p3.x - p1.x) / 6, y: p2.y - (p3.y - p1.y) / 6)
        p.addCurve(to: p2, control1: c1, control2: c2)
    }
    return p
}

/// Renders the icon at `px` pixels. Coordinates are authored on a 1024 canvas, top-left origin.
func render(px: Int, label: Bool) -> CGImage {
    let ctx = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0, space: cs,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.interpolationQuality = .high
    ctx.setAllowsAntialiasing(true)
    let s = CGFloat(px) / 1024
    let small = px <= 32
    ctx.translateBy(x: 0, y: CGFloat(px)); ctx.scaleBy(x: s, y: -s)

    let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
    let tilePath = squircle(tile)

    // Drop shadow
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -12 * s), blur: 28 * s, color: rgb(0x000000, 0.45))
    ctx.addPath(tilePath); ctx.setFillColor(rgb(0x1A2050)); ctx.fillPath()
    ctx.restoreGState()

    // Tile background
    ctx.saveGState()
    ctx.addPath(tilePath); ctx.clip()
    ctx.drawLinearGradient(gradient([rgb(0x181D49), rgb(0x262F66)]),
                           start: CGPoint(x: 512, y: 100), end: CGPoint(x: 512, y: 924), options: [])
    ctx.drawRadialGradient(gradient([rgb(0x4E63C4, 0.34), rgb(0x4E63C4, 0)]),
                           startCenter: CGPoint(x: 470, y: 500), startRadius: 0,
                           endCenter: CGPoint(x: 470, y: 500), endRadius: 460, options: [])

    // Lens geometry
    let cx: CGFloat = 468, cy: CGFloat = 486
    let ringW: CGFloat = small ? 78 : 50
    let R: CGFloat = small ? 262 : 268              // outer radius
    let rc = R - ringW / 2                          // ring centerline
    let ri = R - ringW                              // inner radius
    let dir = CGPoint(x: cos(CGFloat.pi / 4), y: sin(CGFloat.pi / 4))
    let handleW: CGFloat = small ? 84 : 56

    // Label
    if label && !small {
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 74, weight: .heavy),
            .foregroundColor: NSColor(cgColor: rgb(0x4B5C98, 0.62))!,
            .kern: 2.0]
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)
        NSAttributedString(string: "PROC", attributes: attrs).draw(at: CGPoint(x: 156, y: 150))
        NSGraphicsContext.restoreGraphicsState()
    }

    // Glass interior
    let lens = CGPath(ellipseIn: CGRect(x: cx - ri, y: cy - ri, width: ri * 2, height: ri * 2), transform: nil)
    ctx.saveGState()
    ctx.addPath(lens); ctx.clip()
    ctx.drawRadialGradient(gradient([rgb(0x2F3D86), rgb(0x1F2860)]),
                           startCenter: CGPoint(x: cx - 40, y: cy - 60), startRadius: 0,
                           endCenter: CGPoint(x: cx, y: cy), endRadius: ri * 1.05, options: [])

    let left = cx - ri, width = ri * 2, bottom = cy + ri

    // Faint grid
    if !small {
        ctx.setStrokeColor(rgb(0x9FB4FF, 0.10)); ctx.setLineWidth(3)
        for k in 1...3 {
            let y = cy - ri + CGFloat(k) * (ri * 2) / 4
            ctx.move(to: CGPoint(x: left, y: y)); ctx.addLine(to: CGPoint(x: left + width, y: y)); ctx.strokePath()
        }
    }
    // Per-core bars
    if !small {
        let barW: CGFloat = 50
        let xs: [CGFloat] = [-132, -46, 40, 126]
        let hs: [CGFloat] = [250, 330, 205, 285]
        let cols: [UInt32] = [0x8E7BFF, 0x4C9DFF, 0xFFB45A, 0xFF6F9C]
        for i in 0..<4 {
            let r = CGRect(x: cx + xs[i] - barW / 2, y: bottom - hs[i], width: barW, height: hs[i] + 40)
            ctx.addPath(CGPath(roundedRect: r, cornerWidth: 16, cornerHeight: 16, transform: nil))
            ctx.setFillColor(rgb(cols[i], 0.42)); ctx.fillPath()
        }
    }

    // Activity line
    let vals: [CGFloat] = small ? [0.22, 0.50, 0.34, 0.80, 0.55, 0.92] :
        [0.26, 0.40, 0.34, 0.58, 0.50, 0.74, 0.66, 0.88]
    let top = cy - ri * 0.52, base = cy + ri * 0.62
    let pts = vals.enumerated().map { (i, v) -> CGPoint in
        CGPoint(x: left + 34 + (width - 68) * CGFloat(i) / CGFloat(vals.count - 1), y: base - (base - top) * v)
    }
    let line = smoothPath(pts)
    // fill
    let fill = CGMutablePath()
    fill.addPath(line)
    fill.addLine(to: CGPoint(x: pts.last!.x, y: bottom + 10)); fill.addLine(to: CGPoint(x: pts[0].x, y: bottom + 10))
    fill.closeSubpath()
    ctx.saveGState()
    ctx.addPath(fill); ctx.clip()
    ctx.drawLinearGradient(gradient([rgb(0x2DE2A6, small ? 0.55 : 0.62), rgb(0x2BC8F0, 0.10)]),
                           start: CGPoint(x: 0, y: top), end: CGPoint(x: 0, y: bottom), options: [])
    ctx.restoreGState()
    // stroke with horizontal gradient + glow
    let lw: CGFloat = small ? 52 : 26
    ctx.saveGState()
    ctx.setShadow(offset: .zero, blur: 18 * s, color: rgb(0x2DE2D0, 0.7))
    ctx.addPath(line); ctx.setLineWidth(lw); ctx.setLineCap(.round); ctx.setLineJoin(.round)
    ctx.setStrokeColor(rgb(0x35E4B0)); ctx.strokePath()
    ctx.restoreGState()
    ctx.saveGState()
    ctx.addPath(line); ctx.setLineWidth(lw); ctx.setLineCap(.round); ctx.setLineJoin(.round)
    ctx.replacePathWithStrokedPath(); ctx.clip()
    ctx.drawLinearGradient(gradient([rgb(0x3BEA9C), rgb(0x3FE0D6), rgb(0x56C8FF)]),
                           start: CGPoint(x: left, y: 0), end: CGPoint(x: left + width, y: 0), options: [])
    ctx.restoreGState()
    // end dot
    if !small {
        let e = pts.last!
        ctx.setFillColor(rgb(0xE9FFF8)); ctx.fillEllipse(in: CGRect(x: e.x - 11, y: e.y - 11, width: 22, height: 22))
    }
    ctx.restoreGState() // lens clip

    // Magnifier ring + handle with glow
    let ringColor = rgb(0xA9CBFF)
    func magnifier() {
        ctx.addEllipse(in: CGRect(x: cx - rc, y: cy - rc, width: rc * 2, height: rc * 2))
        ctx.setLineWidth(ringW); ctx.setStrokeColor(ringColor); ctx.strokePath()
        ctx.move(to: CGPoint(x: cx + dir.x * (rc + 8), y: cy + dir.y * (rc + 8)))
        ctx.addLine(to: CGPoint(x: cx + dir.x * (rc + 215), y: cy + dir.y * (rc + 215)))
        ctx.setLineWidth(handleW); ctx.setLineCap(.round); ctx.setStrokeColor(ringColor); ctx.strokePath()
    }
    ctx.saveGState()
    ctx.setShadow(offset: .zero, blur: 46 * s, color: rgb(0x7FB0FF, 0.75))
    magnifier()
    ctx.restoreGState()
    ctx.saveGState(); magnifier(); ctx.restoreGState()

    // subtle top highlight on tile
    ctx.drawLinearGradient(gradient([rgb(0xFFFFFF, 0.07), rgb(0xFFFFFF, 0)]),
                           start: CGPoint(x: 512, y: 100), end: CGPoint(x: 512, y: 380), options: [])
    ctx.restoreGState() // tile clip
    return ctx.makeImage()!
}

func writePNG(_ img: CGImage, _ path: String) {
    let rep = NSBitmapImageRep(cgImage: img)
    try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: path))
}

let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "."
let fm = FileManager.default
try? fm.createDirectory(atPath: out + "/AppIcon", withIntermediateDirectories: true)

writePNG(render(px: 1024, label: false), out + "/master.png")
writePNG(render(px: 1024, label: true), out + "/alt.png")

// Primary variant has no label; the label shows only in the alt.
let sizes: [(Int, Int)] = [(16, 1), (16, 2), (32, 1), (32, 2), (128, 1), (128, 2), (256, 1), (256, 2), (512, 1), (512, 2)]
for (pt, sc) in sizes {
    writePNG(render(px: pt * sc, label: false), out + "/AppIcon/icon_\(pt)x\(pt)\(sc == 2 ? "@2x" : "").png")
}

// Preview sheet: light + dark panels
let pw = 1180, ph = 1560
let sheet = CGContext(data: nil, width: pw * 2, height: ph, bitsPerComponent: 8, bytesPerRow: 0, space: cs,
                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
for (i, bg) in [rgb(0xF2F2F7), rgb(0x1C1C1E)].enumerated() {
    let ox = CGFloat(i * pw)
    sheet.setFillColor(bg); sheet.fill(CGRect(x: ox, y: 0, width: CGFloat(pw), height: CGFloat(ph)))
    sheet.draw(render(px: 1024, label: false), in: CGRect(x: ox + 78, y: CGFloat(ph) - 1100, width: 1024, height: 1024))
    var x = ox + 78
    for px in [256, 64, 32, 16] {
        sheet.draw(render(px: px, label: false), in: CGRect(x: x, y: 80, width: CGFloat(px), height: CGFloat(px)))
        x += CGFloat(px) + 90
    }
}
writePNG(sheet.makeImage()!, out + "/preview.png")
print("done")
