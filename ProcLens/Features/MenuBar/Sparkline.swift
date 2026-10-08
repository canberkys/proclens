import SwiftUI

/// Cheap 60 s sparkline. Right-aligned in a fixed time window, so a short history never stretches:
/// empty history is just a flat baseline.
struct Sparkline: View {
    struct Series { let values: [Double]; let color: Color }
    let series: [Series]
    let maxValue: Double
    let capacity: Int

    var body: some View {
        Canvas { ctx, size in
            let h = size.height, w = size.width
            var base = Path()
            base.move(to: CGPoint(x: 0, y: h - 0.5)); base.addLine(to: CGPoint(x: w, y: h - 0.5))
            ctx.stroke(base, with: .color(.secondary.opacity(0.25)), lineWidth: 1)
            let step = w / CGFloat(max(1, capacity - 1))
            for s in series where s.values.count >= 2 {
                let n = s.values.count
                var line = Path()
                for (i, v) in s.values.enumerated() {
                    let x = w - CGFloat(n - 1 - i) * step
                    let y = (h - 1) - CGFloat(min(1, max(0, v / maxValue))) * (h - 3)
                    i == 0 ? line.move(to: CGPoint(x: x, y: y)) : line.addLine(to: CGPoint(x: x, y: y))
                }
                var area = line
                area.addLine(to: CGPoint(x: w, y: h)); area.addLine(to: CGPoint(x: w - CGFloat(n - 1) * step, y: h))
                area.closeSubpath()
                ctx.fill(area, with: .color(s.color.opacity(0.15)))
                ctx.stroke(line, with: .color(s.color), style: StrokeStyle(lineWidth: 1.2, lineJoin: .round))
            }
        }
        .drawingGroup(opaque: false)
    }

    /// Smallest 1-2-5 step >= v (>= floor): the axis only moves when the peak crosses a step.
    static func niceMax(_ v: Double, minimum: Double = 100_000) -> Double {
        var m = minimum
        while m < v { m = nextStep(m) }
        return m
    }
    private static func nextStep(_ m: Double) -> Double {
        let mag = pow(10, log10(m).rounded(.down))
        let lead = (m / mag).rounded()
        return lead < 2 ? 2 * mag : lead < 5 ? 5 * mag : 10 * mag
    }
}
