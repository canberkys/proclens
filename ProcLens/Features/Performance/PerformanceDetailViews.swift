import SwiftUI
import ProcLensCore

private struct Header: View {
    let title: String
    let subtitle: String
    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title).font(.title2.bold())
            Spacer()
            Text(subtitle).foregroundStyle(.secondary)
        }
    }
}

private struct Stat: View {
    let name: String
    let value: String
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(name).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.title3).monospacedDigit()
        }
    }
}

private let statColumns = [GridItem(.adaptive(minimum: 130), alignment: .topLeading)]

// MARK: CPU

struct CPUDetail: View {
    let vm: PerformanceViewModel
    let latest: SystemSnapshot?
    let interval: SamplingInterval

    var body: some View {
        let cores = latest?.cpu?.cores ?? []
        let p = cores.filter { $0.kind == .performance }
        let e = cores.filter { $0.kind == .efficiency }
        let total = latest?.cpu?.total ?? 0
        let user = cores.isEmpty ? 0 : cores.reduce(0) { $0 + $1.user } / Double(cores.count)
        let sys = cores.isEmpty ? 0 : cores.reduce(0) { $0 + $1.system } / Double(cores.count)

        VStack(alignment: .leading, spacing: 14) {
            Header(title: "CPU", subtitle: "% utilization over 60 seconds")
            TimeChart(series: [.init(id: "cpu", points: vm.primary, color: .accentColor)],
                      label: "CPU utilization, last 60 seconds", summary: Format.percent(total))
                .frame(height: 200).cardBackground()
            LazyVGrid(columns: statColumns, spacing: 12) {
                Stat(name: "Utilization", value: Format.percent(total))
                Stat(name: "User", value: Format.percent(user))
                Stat(name: "System", value: Format.percent(sys))
                Stat(name: "Cores", value: "\(cores.count) (\(p.count) P + \(e.count) E)")
                Stat(name: "Sampling", value: "\(interval.rawValue.formatted()) s")
            }
            coreGrid(title: "Performance cores", kind: .performance, cores: cores)
            coreGrid(title: "Efficiency cores", kind: .efficiency, cores: cores)
            coreGrid(title: "Cores", kind: .unknown, cores: cores)
        }
    }

    @ViewBuilder
    private func coreGrid(title: String, kind: CoreKind, cores: [CPUCoreSample]) -> some View {
        let items = cores.enumerated().filter { $0.element.kind == kind }
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text(title).font(.headline)
                CoreTileGrid(
                    tiles: items.map { pos, core in
                        .init(label: "Core \(core.index)  \(Format.percent(core.total))",
                              points: pos < vm.perCore.count ? vm.perCore[pos] : [])
                    },
                    color: kind == .efficiency ? .green : .accentColor)
            }
        }
    }
}

private struct GridWidthKey: PreferenceKey {
    static let defaultValue: CGFloat = 520
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

/// All per-core tiles in ONE Canvas: ~14 tiles x (stack + text + chart) as separate SwiftUI views cost far more
/// per tick (view-graph diffing) than drawing them directly.
private struct CoreTileGrid: View {
    struct Tile { let label: String; let points: [ChartPoint] }
    let tiles: [Tile]
    let color: Color

    private static let minWidth: CGFloat = 110, spacing: CGFloat = 8, tileHeight: CGFloat = 70

    var body: some View {
        Canvas { ctx, size in
            let cols = max(1, Int((size.width + Self.spacing) / (Self.minWidth + Self.spacing)))
            let tileW = (size.width - Self.spacing * CGFloat(cols - 1)) / CGFloat(cols)
            for (i, t) in tiles.enumerated() {
                let origin = CGPoint(x: CGFloat(i % cols) * (tileW + Self.spacing),
                                     y: CGFloat(i / cols) * (Self.tileHeight + Self.spacing))
                let rect = CGRect(origin: origin, size: CGSize(width: tileW, height: Self.tileHeight))
                ctx.fill(Path(roundedRect: rect, cornerRadius: 8), with: .color(.gray.opacity(0.15)))
                ctx.draw(Text(t.label).font(.caption2).monospacedDigit(), at: CGPoint(x: rect.minX + 10, y: rect.minY + 12), anchor: .leading)
                let plot = CGRect(x: rect.minX + 10, y: rect.minY + 22, width: tileW - 20, height: Self.tileHeight - 32)
                guard t.points.count > 1 else { continue }
                var line = Path()
                for (j, p) in t.points.enumerated() {
                    let x = plot.minX + (p.x + 60) / 60 * plot.width
                    let y = plot.maxY - CGFloat(min(1, max(0, p.y))) * plot.height
                    if j == 0 { line.move(to: CGPoint(x: x, y: y)) } else { line.addLine(to: CGPoint(x: x, y: y)) }
                }
                var area = line
                area.addLine(to: CGPoint(x: plot.maxX, y: plot.maxY))
                area.addLine(to: CGPoint(x: plot.minX + (t.points[0].x + 60) / 60 * plot.width, y: plot.maxY))
                area.closeSubpath()
                ctx.fill(area, with: .color(color.opacity(0.18)))
                ctx.stroke(line, with: .color(color), lineWidth: 1)
            }
        }
        .frame(height: gridHeight)
        .background(GeometryReader { g in Color.clear.preference(key: GridWidthKey.self, value: g.size.width) })
        .onPreferenceChange(GridWidthKey.self) { if abs($0 - width) > 0.5 { width = $0 } }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(tiles.map(\.label).joined(separator: ", "))
    }

    /// Measured width of the grid; drives the row count (and so the height).
    @State private var width: CGFloat = 520
    private var gridHeight: CGFloat {
        let cols = max(1, Int((width + Self.spacing) / (Self.minWidth + Self.spacing)))
        let rows = (tiles.count + cols - 1) / cols
        return CGFloat(rows) * Self.tileHeight + CGFloat(max(0, rows - 1)) * Self.spacing
    }
}

// MARK: Memory

struct MemoryDetail: View {
    let vm: PerformanceViewModel
    let latest: SystemSnapshot?

    var body: some View {
        let m = latest?.memory
        VStack(alignment: .leading, spacing: 14) {
            Header(title: "Memory", subtitle: m.map { Format.bytes($0.total) } ?? "")
            TimeChart(series: [.init(id: "mem", points: vm.primary, color: .accentColor)],
                      label: "Memory in use, last 60 seconds",
                      summary: m.map { Format.bytes($0.used) } ?? "unknown")
                .frame(height: 200).cardBackground()
            if let m {
                CompositionBar(m: m)
                LazyVGrid(columns: statColumns, spacing: 12) {
                    Stat(name: "In use", value: Format.bytes(m.used))
                    Stat(name: "Total", value: Format.bytes(m.total))
                    Stat(name: "Swap used", value: Format.bytes(m.swapUsed))
                    Stat(name: "Cached", value: Format.bytes(m.cached))
                    Stat(name: "Compressed", value: Format.bytes(m.compressed))
                }
                HStack(spacing: 6) {
                    Circle().fill(pressureColor(m.pressure)).frame(width: 10, height: 10)
                    Text("Memory pressure: \(m.pressure.rawValue.capitalized)")
                }
                .accessibilityElement(children: .combine)
            }
        }
    }

    private func pressureColor(_ p: MemoryPressure) -> Color {
        switch p { case .normal: .green; case .warning: .yellow; case .critical: .red }
    }
}

private struct CompositionBar: View {
    let m: MemorySample

    var body: some View {
        let free = m.total > m.used + m.cached ? m.total - m.used - m.cached : 0
        let parts: [(String, UInt64, Color)] = [
            ("App", m.app, .blue), ("Wired", m.wired, .orange), ("Compressed", m.compressed, .purple),
            ("Cached", m.cached, .teal), ("Free", free, Color.secondary.opacity(0.25)),
        ]
        VStack(alignment: .leading, spacing: 6) {
            Text("Memory composition").font(.headline)
            GeometryReader { geo in
                HStack(spacing: 1) {
                    ForEach(parts, id: \.0) { _, bytes, color in
                        Rectangle().fill(color)
                            .frame(width: geo.size.width * Double(bytes) / Double(max(1, m.total)))
                    }
                    Spacer(minLength: 0)
                }
                .clipShape(RoundedRectangle(cornerRadius: 4))
            }
            .frame(height: 22)
            HStack(spacing: 14) {
                ForEach(parts, id: \.0) { name, bytes, color in
                    HStack(spacing: 4) {
                        RoundedRectangle(cornerRadius: 2).fill(color).frame(width: 10, height: 10)
                        Text("\(name) \(Format.bytes(bytes))").font(.caption).monospacedDigit()
                    }
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Memory composition")
        .accessibilityValue(parts.map { "\($0.0) \(Format.bytes($0.1))" }.joined(separator: ", "))
    }
}

// MARK: Disk

struct DiskDetail: View {
    let vm: PerformanceViewModel
    let latest: SystemSnapshot?

    var body: some View {
        let d = latest?.disk
        VStack(alignment: .leading, spacing: 14) {
            Header(title: "Disk", subtitle: "Read / write throughput")
            TimeChart(series: [.init(id: "read", points: vm.primary, color: .accentColor),
                               .init(id: "write", points: vm.secondary, color: .orange)],
                      yDomain: 0...vm.diskMax, yFormat: { Format.rate($0) },
                      label: "Disk read and write rate, last 60 seconds",
                      summary: "Read \(Format.rate(d?.readPerSec ?? 0)), write \(Format.rate(d?.writePerSec ?? 0))")
                .frame(height: 200).cardBackground()
            HStack(spacing: 24) {
                Stat(name: "Read", value: Format.rate(d?.readPerSec ?? 0))
                Stat(name: "Write", value: Format.rate(d?.writePerSec ?? 0))
            }
            LegendRow(items: [("Read", .accentColor), ("Write", .orange)])
        }
    }
}

private struct LegendRow: View {
    let items: [(String, Color)]
    var body: some View {
        HStack(spacing: 14) {
            ForEach(items, id: \.0) { name, color in
                HStack(spacing: 4) {
                    RoundedRectangle(cornerRadius: 2).fill(color).frame(width: 10, height: 10)
                    Text(name).font(.caption)
                }
            }
        }
        .accessibilityHidden(true)
    }
}

// MARK: Network

struct NetworkDetail: View {
    let vm: PerformanceViewModel
    let latest: SystemSnapshot?
    @State private var showAll = false

    var body: some View {
        let n = latest?.network
        let ifaces = (n?.physicalInterfaces ?? []).filter { showAll || $0.receivedPerSec + $0.sentPerSec > 0 }
        VStack(alignment: .leading, spacing: 14) {
            Header(title: "Network", subtitle: "Receive / send")
            TimeChart(series: [.init(id: "rx", points: vm.primary, color: .accentColor),
                               .init(id: "tx", points: vm.secondary, color: .orange)],
                      yDomain: 0...vm.networkMax, yFormat: { Format.bitsRate($0) },
                      label: "Network receive and send rate, last 60 seconds",
                      summary: "Receive \(Format.bitsRate(n?.receivedPerSec ?? 0)), send \(Format.bitsRate(n?.sentPerSec ?? 0))")
                .frame(height: 200).cardBackground()
            HStack(spacing: 24) {
                Stat(name: "Receive", value: Format.bitsRate(n?.receivedPerSec ?? 0))
                Stat(name: "Send", value: Format.bitsRate(n?.sentPerSec ?? 0))
            }
            LegendRow(items: [("Receive", .accentColor), ("Send", .orange)])
            HStack {
                Text("Interfaces").font(.headline)
                Spacer()
                Toggle("Show all", isOn: $showAll).toggleStyle(.checkbox)
            }
            if ifaces.isEmpty {
                Text("No active interfaces").foregroundStyle(.secondary)
            } else {
                Grid(alignment: .leading, horizontalSpacing: 20, verticalSpacing: 6) {
                    GridRow {
                        Text("Name").foregroundStyle(.secondary)
                        Text("Receive").foregroundStyle(.secondary)
                        Text("Send").foregroundStyle(.secondary)
                    }
                    ForEach(ifaces, id: \.name) { i in
                        GridRow {
                            Text(i.name)
                            Text(Format.bitsRate(i.receivedPerSec)).monospacedDigit()
                            Text(Format.bitsRate(i.sentPerSec)).monospacedDigit()
                        }
                    }
                }
            }
        }
    }
}

// MARK: GPU

struct GPUDetail: View {
    let vm: PerformanceViewModel
    let latest: SystemSnapshot?

    var body: some View {
        let devices = latest?.gpu?.devices ?? []
        VStack(alignment: .leading, spacing: 14) {
            Header(title: "GPU", subtitle: devices.first?.name ?? "")
            if devices.isEmpty {
                Text("No GPU data available").foregroundStyle(.secondary)
            }
            ForEach(Array(devices.enumerated()), id: \.offset) { i, dev in
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text(dev.name).font(.headline)
                        Spacer()
                        Text(Format.percent(dev.utilization)).monospacedDigit()
                    }
                    TimeChart(series: [.init(id: "gpu\(i)", points: i < vm.perDevice.count ? vm.perDevice[i] : [], color: .accentColor)],
                              label: "\(dev.name) utilization, last 60 seconds", summary: Format.percent(dev.utilization))
                        .frame(height: 200)
                }
                .cardBackground()
            }
        }
    }
}
