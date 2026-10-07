import SwiftUI
import Charts

/// Time-series chart, x = seconds ago (-60...0). Animations are disabled so ticks do not tween.
struct TimeChart: View {
    struct Series: Identifiable {
        let id: String
        let points: [ChartPoint]
        let color: Color
        var filled = true
    }

    let series: [Series]
    var yDomain: ClosedRange<Double> = 0...1
    var yFormat: (Double) -> String = { Format.percent($0) }
    let label: String
    let summary: String
    var showAxes = true

    var body: some View {
        if showAxes { chart } else { sparkline }
    }

    /// Axis-less charts (5 sidebar cards + up to ~20 per-core tiles) are drawn with a plain Canvas:
    /// Swift Charts re-lays-out every mark each tick, which was the dominant cost of the Performance tab.
    private var sparkline: some View {
        Canvas { ctx, size in
            let lo = yDomain.lowerBound, span = max(1e-9, yDomain.upperBound - lo)
            for s in series {
                guard s.points.count > 1 else { continue }
                var line = Path()
                for (i, p) in s.points.enumerated() {
                    let x = (p.x + 60) / 60 * size.width
                    let y = size.height - CGFloat(min(1, max(0, (p.y - lo) / span))) * size.height
                    if i == 0 { line.move(to: CGPoint(x: x, y: y)) } else { line.addLine(to: CGPoint(x: x, y: y)) }
                }
                if s.filled, let first = s.points.first, let last = s.points.last {
                    var area = line
                    area.addLine(to: CGPoint(x: (last.x + 60) / 60 * size.width, y: size.height))
                    area.addLine(to: CGPoint(x: (first.x + 60) / 60 * size.width, y: size.height))
                    area.closeSubpath()
                    ctx.fill(area, with: .color(s.color.opacity(0.18)))
                }
                ctx.stroke(line, with: .color(s.color), lineWidth: 1)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
        .accessibilityValue(summary)
    }

    private var chart: some View {
        Chart {
            ForEach(series) { s in
                ForEach(s.points, id: \.x) { p in
                    if s.filled {
                        AreaMark(x: .value("t", p.x), y: .value("v", p.y), series: .value("s", s.id))
                            .foregroundStyle(s.color.opacity(0.18))
                    }
                    LineMark(x: .value("t", p.x), y: .value("v", p.y), series: .value("s", "l" + s.id))
                        .foregroundStyle(s.color)
                        .lineStyle(StrokeStyle(lineWidth: showAxes ? 1.5 : 1))
                }
            }
        }
        .chartXScale(domain: -60...0)
        .chartYScale(domain: yDomain)
        .chartXAxis(showAxes ? .automatic : .hidden)
        .chartYAxis(showAxes ? .automatic : .hidden)
        .chartXAxis {
            if showAxes {
                AxisMarks(values: [-60, -45, -30, -15, 0]) { v in
                    AxisGridLine()
                    AxisValueLabel { if let d = v.as(Double.self) { Text(d == 0 ? "now" : "\(Int(d))s") } }
                }
            }
        }
        .chartYAxis {
            if showAxes {
                AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) { v in
                    AxisGridLine()
                    AxisValueLabel { if let d = v.as(Double.self) { Text(yFormat(d)) } }
                }
            }
        }
        .chartLegend(.hidden)
        .transaction { $0.animation = nil }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
        .accessibilityValue(summary)
    }
}

extension View {
    func cardBackground() -> some View {
        padding(10).background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
    }
}
