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
