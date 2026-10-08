import Charts
import ProcLensCore
import SwiftUI

/// "What spiked at 14:32?": a one-hour system timeline with spike markers; click or drag selects a moment
/// and lists the top processes of that 10 s bucket.
struct HistoryView: View {
    @Environment(AppModel.self) private var model

    @State private var metric: HistoryMetric = .cpu
    @State private var percentThreshold: Double = 80
    @State private var rateThresholdMB: Double = 100
    @State private var sort: HistoryProcessSort = .cpu
    @State private var chart = ChartData.empty
    @State private var hover: Date?
    @State private var pinned: Date?
    @State private var top: [HistoryProcessEntry] = []
    @State private var sparks: [ProcessID: [Double]] = [:]
    @State private var showAlerts = false
    #if DEBUG
    @State private var debugAgo: Double?
    #endif

    private static let window: TimeInterval = ProcessHistory.totalWindow

    var body: some View {
        VStack(spacing: 0) {
            controls
            Divider()
            HStack(spacing: 0) {
                chartPane
                Divider()
                processPane.frame(width: 320)
            }
        }
        .navigationTitle("History")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { showAlerts = true } label: { Label("Alerts…", systemImage: "bell.badge") }
                    .help("Edit alert rules")
            }
        }
        .sheet(isPresented: $showAlerts) { AlertRulesView() }
        .task(id: metric) {
            #if DEBUG
            let dbg = await DebugHistory.apply(model: model)
            debugAgo = dbg.ago
            if dbg.showAlerts { showAlerts = true }
            #endif
            while !Task.isCancelled {
                await reload()
                try? await Task.sleep(for: .seconds(10))
            }
        }
        .task(id: Selection(date: pinned, sort: sort, tick: chart.generation)) { await loadTop() }
        .onChange(of: hover) { _, new in
            if let new { pinned = Self.snap(new, in: chart.domain) }
        }
        .onChange(of: percentThreshold) { Task { await reload() } }
        .onChange(of: rateThresholdMB) { Task { await reload() } }
    }

    private struct Selection: Hashable {
        let date: Date?
        let sort: HistoryProcessSort
        let tick: Int
    }

    // MARK: Controls

    private var controls: some View {
        HStack(spacing: 16) {
            Picker("Metric", selection: $metric) {
                Text("CPU").tag(HistoryMetric.cpu)
                Text("Memory").tag(HistoryMetric.memory)
                Text("Disk").tag(HistoryMetric.disk)
                Text("Network").tag(HistoryMetric.network)
                Text("GPU").tag(HistoryMetric.gpu)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: 360)
            Spacer()
            HStack(spacing: 8) {
                Text("Spike threshold").foregroundStyle(.secondary)
                if metric.isPercent {
                    Slider(value: $percentThreshold, in: 10...100, step: 1).frame(width: 140)
                    Text("\(Int(percentThreshold))%").monospacedDigit().frame(width: 44, alignment: .trailing)
                } else {
                    Slider(value: $rateThresholdMB, in: 1...1000, step: 1).frame(width: 140)
                    Text("\(Int(rateThresholdMB)) MB/s").monospacedDigit().frame(width: 74, alignment: .trailing)
                }
            }
            .font(.callout)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    // MARK: Chart

    private var chartPane: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("\(metric.title) history").font(.headline)
                Spacer()
                Text(chart.spikeDates.isEmpty ? "No spikes" : "\(chart.spikeDates.count) spike bucket\(chart.spikeDates.count == 1 ? "" : "s")")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Chart {
                ForEach(chart.points) { p in
                    AreaMark(x: .value("Time", p.date), y: .value(metric.title, p.value),
                             series: .value("Segment", p.segment), stacking: .unstacked)
                        .foregroundStyle(LinearGradient(colors: [Color.accentColor.opacity(0.28), Color.accentColor.opacity(0.03)],
                                                        startPoint: .top, endPoint: .bottom))
                        .interpolationMethod(.linear)
                    LineMark(x: .value("Time", p.date), y: .value(metric.title, p.value), series: .value("Segment", p.segment))
                        .foregroundStyle(Color.accentColor)
                        .lineStyle(StrokeStyle(lineWidth: 1.5, lineJoin: .round))
                        .interpolationMethod(.linear)
                }
                if metric.isPercent {
                    RuleMark(y: .value("Threshold", percentThreshold))
                        .foregroundStyle(.orange.opacity(0.7))
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
                } else {
                    RuleMark(y: .value("Threshold", rateThresholdMB * 1e6 / chart.scale.divisor))
                        .foregroundStyle(.orange.opacity(0.7))
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
                }
                ForEach(chart.spikes) { s in
                    PointMark(x: .value("Time", s.date), y: .value(metric.title, s.value))
                        .symbol(.circle).symbolSize(46)
                        .foregroundStyle(.red)
                }
                if let pinned {
                    RuleMark(x: .value("Selected", pinned))
                        .foregroundStyle(.secondary)
                        .lineStyle(StrokeStyle(lineWidth: 1))
                        .annotation(position: .top, alignment: .center, spacing: 0, overflowResolution: .init(x: .fit(to: .chart), y: .disabled)) {
                            Text(pinned.formatted(date: .omitted, time: .standard))
                                .font(.caption.monospacedDigit())
                                .padding(.horizontal, 6).padding(.vertical, 2)
                                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 4))
                        }
                }
            }
            .padding(.top, 24)
            .chartXScale(domain: chart.domain)
            .chartYScale(domain: 0...chart.yMax)
            .chartXSelection(value: $hover)
            .chartXAxis {
                AxisMarks(values: .stride(by: .minute, count: chart.tickMinutes)) { _ in
                    AxisGridLine(); AxisTick()
                    AxisValueLabel(format: .dateTime.hour().minute(), anchor: .top)
                }
            }
            .chartYAxis {
                AxisMarks(position: .leading, values: chart.yTicks) { value in
                    AxisGridLine()
                    AxisValueLabel {
                        if let v = value.as(Double.self) { Text(chart.scale.label(v)).monospacedDigit() }
                    }
                }
            }
            .transaction { $0.animation = nil }
            .overlay {
                if chart.points.count < 6 {
                    VStack(spacing: 4) {
                        Text("Collecting…").font(.title3.weight(.medium))
                        Text("History fills as ProcLens runs; keep the window open or enable Background monitoring.")
                            .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    }
                    .padding(16)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
                    .allowsHitTesting(false)
                }
            }
            Text("Click or drag on the chart to see the top processes at that moment. Red dots are spikes above the threshold.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(16)
        .frame(minWidth: 380, maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Process list

    private var processPane: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(pinned.map { "Top processes at \($0.formatted(date: .omitted, time: .standard))" } ?? "Top processes")
                    .font(.headline).lineLimit(1)
                Spacer()
            }
            Picker("Sort", selection: $sort) {
                Text("CPU").tag(HistoryProcessSort.cpu)
                Text("Memory").tag(HistoryProcessSort.memory)
            }
            .pickerStyle(.segmented).labelsHidden()
            if pinned == nil {
                ContentUnavailableView("Pick a moment", systemImage: "cursorarrow.click.2",
                                       description: Text("Click or drag on the chart."))
            } else if top.isEmpty {
                ContentUnavailableView("No data", systemImage: "tray",
                                       description: Text("No process data was recorded for this moment."))
            } else {
                List(top) { entry in
                    HStack(spacing: 8) {
                        Text(entry.name).lineLimit(1).truncationMode(.middle)
                        Spacer(minLength: 4)
                        if let s = sparks[entry.id], s.count >= 2 {
                            HistorySparkline(values: s).frame(width: 56, height: 16)
                        }
                        Text(sort == .cpu ? Format.cpuPercent(entry.cpu) : Format.bytes(entry.memory))
                            .monospacedDigit().foregroundStyle(.secondary)
                            .frame(width: 66, alignment: .trailing)
                    }
                }
                .listStyle(.plain)
            }
        }
        .padding(16)
    }

    // MARK: Loading

    private func reload() async {
        let history = model.services.history
        let end = Date(timeIntervalSince1970: (Date().timeIntervalSince1970 / 10).rounded(.up) * 10)
        let range = end.addingTimeInterval(-Self.window)...end
        let m = metric
        let raw = await history.systemSeries(metric: m, range: range)
        let spikeThreshold = m.isPercent ? percentThreshold / 100 * m.fullScale : rateThresholdMB * 1e6
        let spikeBuckets = await history.spikes(metric: m, threshold: spikeThreshold, in: range)
        guard m == metric else { return }
        // Show the covered part of the hour (at least 5 min) so a short history is not a sliver at the right edge.
        let first = raw.first?.0 ?? end
        let start = min(max(first, range.lowerBound), end.addingTimeInterval(-300))
        var data = ChartData.build(metric: m, raw: raw, spikeBuckets: spikeBuckets, domain: start...end)
        data.generation = chart.generation + 1
        chart = data
        #if DEBUG
        if pinned == nil, let ago = debugAgo, raw.count >= 6, let last = raw.last?.0 {
            pinned = Self.snap(last.addingTimeInterval(-ago), in: chart.domain)
        }
        #endif
    }

    private func loadTop() async {
        guard let pinned else { top = []; sparks = [:]; return }
        let history = model.services.history
        let entries = await history.topProcesses(at: pinned, by: sort)
        var s: [ProcessID: [Double]] = [:]
        for e in entries {
            let pts = await history.series(for: e.id)
            s[e.id] = pts.map { sort == .cpu ? $0.cpu : Double($0.memory) }
        }
        guard !Task.isCancelled else { return }
        top = entries
        sparks = s
    }

    /// Snap to the 10 s bucket start so the marker and the list agree.
    private static func snap(_ date: Date, in domain: ClosedRange<Date>) -> Date {
        let clamped = min(max(date, domain.lowerBound), domain.upperBound)
        return Date(timeIntervalSince1970: (clamped.timeIntervalSince1970 / 10).rounded(.down) * 10)
    }
}

// MARK: - Chart data

private extension HistoryMetric {
    var isPercent: Bool { self == .cpu || self == .memory || self == .gpu }

    var title: String {
        switch self {
        case .cpu: "CPU"
        case .memory: "Memory"
        case .disk: "Disk"
        case .network: "Network"
        case .gpu: "GPU"
        }
    }

    /// Raw value that corresponds to 100%.
    var fullScale: Double {
        switch self {
        case .memory: Double(ProcessInfo.processInfo.physicalMemory)
        default: 1
        }
    }
}

private struct RateScale {
    let divisor: Double
    let unit: String
    func label(_ v: Double) -> String {
        if unit == "%" { return "\(Int(v))%" }
        return v == v.rounded() ? "\(Int(v)) \(unit)" : String(format: "%.1f %@", v, unit)
    }
    static let percent = RateScale(divisor: 1, unit: "%")
}

private struct ChartData {
    struct Point: Identifiable { let id: Int; let date: Date; let value: Double; let segment: Int }
    struct Spike: Identifiable { var id: Date { date }; let date: Date; let value: Double }

    var points: [Point]
    var spikes: [Spike]
    var spikeDates: [Date]
    var domain: ClosedRange<Date>
    var yMax: Double
    var yTicks: [Double]
    var scale: RateScale
    var generation = 0
    var tickMinutes: Int {
        let span = domain.upperBound.timeIntervalSince(domain.lowerBound)
        return span <= 600 ? 1 : span <= 1800 ? 5 : 10
    }

    static let empty = ChartData(points: [], spikes: [], spikeDates: [],
                                 domain: Date().addingTimeInterval(-3600)...Date(), yMax: 100, yTicks: [0, 25, 50, 75, 100], scale: .percent)

    static func build(metric: HistoryMetric, raw: [(Date, Double)], spikeBuckets: [Date], domain: ClosedRange<Date>) -> ChartData {
        let scale: RateScale
        let factor: Double
        let yMax: Double
        if metric.isPercent {
            scale = .percent
            factor = 100 / metric.fullScale
            yMax = 100
        } else {
            let peak = raw.map(\.1).max() ?? 0
            let niceBytes = niceCeil(max(peak * 1.15, 100_000))
            let (div, unit): (Double, String) = niceBytes >= 1e9 ? (1e9, "GB/s") : niceBytes >= 1e6 ? (1e6, "MB/s") : (1e3, "KB/s")
            scale = RateScale(divisor: div, unit: unit)
            factor = 1 / div
            yMax = niceBytes / div
        }
        var points: [Point] = []
        var segment = 0
        var prev: Date?
        for (i, (d, v)) in raw.enumerated() {
            // The history has holes when the full sampler was off; do not draw lines across them.
            if let p = prev, d.timeIntervalSince(p) > 25 { segment += 1 }
            prev = d
            points.append(Point(id: i, date: d, value: min(v * factor, yMax), segment: segment))
        }
        var spikes: [Spike] = []
        for start in spikeBuckets {
            let inBucket = points.filter { $0.date >= start && $0.date < start.addingTimeInterval(10) }
            if let peak = inBucket.max(by: { $0.value < $1.value }) { spikes.append(Spike(date: peak.date, value: peak.value)) }
        }
        let ticks: [Double] = metric.isPercent ? [0, 25, 50, 75, 100] : (0...4).map { yMax * Double($0) / 4 }
        return ChartData(points: points, spikes: spikes, spikeDates: spikeBuckets, domain: domain, yMax: yMax, yTicks: ticks, scale: scale)
    }

    /// 1, 2, 5 x 10^n at or above `v`.
    static func niceCeil(_ v: Double) -> Double {
        let exp = pow(10, floor(log10(v)))
        for m in [1.0, 2, 4, 5, 10] where m * exp >= v { return m * exp }
        return 10 * exp
    }
}

private struct HistorySparkline: View {
    let values: [Double]

    var body: some View {
        Canvas { ctx, size in
            let hi = max(values.max() ?? 0, 0.0001)
            var path = Path()
            for (i, v) in values.enumerated() {
                let x = size.width * CGFloat(i) / CGFloat(values.count - 1)
                let y = size.height - size.height * CGFloat(v / hi)
                if i == 0 { path.move(to: CGPoint(x: x, y: y)) } else { path.addLine(to: CGPoint(x: x, y: y)) }
            }
            ctx.stroke(path, with: .color(.accentColor), lineWidth: 1)
        }
        .accessibilityHidden(true)
    }
}

#if DEBUG
/// Debug launch arguments, all optional:
///   -ProcLensHistoryAt <seconds ago>   preselect that moment
///   -ProcLensAlertsSheet 1              open the alerts sheet
///   -ProcLensAlertSelfTest 1            install "Any process CPU >= 50% for 5 s" in memory (not saved), log events
@MainActor
enum DebugHistory {
    static func apply(model: AppModel) async -> (ago: Double?, showAlerts: Bool) {
        AlertNotifier.shared.start(services: model.services)
        let d = UserDefaults.standard
        let ago: Double? = d.object(forKey: "ProcLensHistoryAt") != nil ? d.double(forKey: "ProcLensHistoryAt") : nil
        if d.bool(forKey: "ProcLensAlertSelfTest") {
            let rule = AlertRule(name: "Any process CPU ≥ 50% for 5 s", target: .anyProcess, metric: .cpu,
                                 threshold: 50, durationSeconds: 5, cooldownSeconds: 30)
            await model.services.alerts.setRules([rule])
        }
        return (ago, d.bool(forKey: "ProcLensAlertsSheet"))
    }
}
#endif
