import SwiftUI
import ProcLensCore

struct PerformanceView: View {
    @Environment(AppModel.self) private var model
    @State private var vm = PerformanceViewModel()

    var body: some View {
        HStack(spacing: 0) {
            ScrollView {
                VStack(spacing: 6) {
                    ForEach(PerformanceResource.allCases) { r in
                        ResourceCard(resource: r, vm: vm, latest: model.latest, selected: vm.selection == r)
                            .onTapGesture { vm.selection = r }
                    }
                }
                .padding(10)
            }
            .frame(width: 230)
            Divider()
            ScrollView {
                Group {
                    switch vm.selection {
                    case .cpu: CPUDetail(vm: vm, latest: model.latest, interval: model.interval)
                    case .memory: MemoryDetail(vm: vm, latest: model.latest)
                    case .disk: DiskDetail(vm: vm, latest: model.latest)
                    case .network: NetworkDetail(vm: vm, latest: model.latest)
                    case .gpu: GPUDetail(vm: vm, latest: model.latest)
                    }
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .onAppear { vm.refresh(history: model.history, latest: model.latest) }
        .onChange(of: model.latest?.tick) { vm.refresh(history: model.history, latest: model.latest) }
        .onChange(of: vm.selection) { vm.refresh(history: model.history, latest: model.latest) }
    }
}

private struct ResourceCard: View {
    let resource: PerformanceResource
    let vm: PerformanceViewModel
    let latest: SystemSnapshot?
    let selected: Bool

    var body: some View {
        HStack(spacing: 8) {
            TimeChart(series: [.init(id: resource.rawValue, points: points, color: color)],
                      yDomain: domain, label: "\(resource.rawValue) last 60 seconds", summary: value, showAxes: false)
                .frame(width: 64, height: 40)
                .overlay(RoundedRectangle(cornerRadius: 2).stroke(color.opacity(0.5), lineWidth: 0.5))
            VStack(alignment: .leading, spacing: 2) {
                Label(resource.rawValue, systemImage: resource.symbol).font(.headline)
                Text(value).font(.caption).foregroundStyle(.secondary).monospacedDigit()
            }
            Spacer(minLength: 0)
        }
        .padding(8)
        .background(selected ? Color.accentColor.opacity(0.18) : Color.clear, in: RoundedRectangle(cornerRadius: 8))
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }

    private var color: Color { .accentColor }

    private var points: [ChartPoint] {
        switch resource {
        case .cpu: vm.sparkCPU
        case .memory: vm.sparkMemory
        case .disk: vm.sparkDisk
        case .network: vm.sparkNetwork
        case .gpu: vm.sparkGPU
        }
    }

    private var domain: ClosedRange<Double> {
        switch resource {
        case .cpu, .memory, .gpu: 0...1
        case .disk, .network: 0...max(1_000_000, points.map(\.y).max() ?? 0)
        }
    }

    private var value: String {
        guard let s = latest else { return "–" }
        switch resource {
        case .cpu: return s.cpu.map { Format.percent($0.total) } ?? "–"
        case .memory: return s.memory.map { "\(Format.bytes($0.used)) (\(Format.percent(Double($0.used) / Double(max(1, $0.total)))))" } ?? "–"
        case .disk: return s.disk.map { "R \(Format.rate($0.readPerSec))  W \(Format.rate($0.writePerSec))" } ?? "–"
        case .network: return s.network.map { "↓ \(Format.bitsRate($0.receivedPerSec))  ↑ \(Format.bitsRate($0.sentPerSec))" } ?? "–"
        case .gpu: return s.gpu.map { Format.percent($0.utilization) } ?? "–"
        }
    }
}
