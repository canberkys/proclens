import Foundation
import Observation
import ProcLensCore

enum PerformanceResource: String, CaseIterable, Identifiable {
    case cpu = "CPU", memory = "Memory", disk = "Disk", network = "Network", gpu = "GPU"
    var id: String { rawValue }
    var symbol: String {
        switch self {
        case .cpu: "cpu"
        case .memory: "memorychip"
        case .disk: "internaldrive"
        case .network: "network"
        case .gpu: "display"
        }
    }
}

/// One chart sample. `x` is seconds before the latest snapshot (-60...0).
struct ChartPoint: Hashable {
    let x: Double
    let y: Double
}

/// Holds lightweight chart arrays. Sparklines for the five cards are rebuilt each tick
/// (one pass over history, ~60 points each); the heavy detail series (per-core, two-series
/// charts, per-device GPU) are built only for the selected pane.
@Observable @MainActor
final class PerformanceViewModel {
    var selection: PerformanceResource = .cpu {
        didSet { if selection != oldValue { detailTick = nil } }
    }

    private(set) var sparkCPU: [ChartPoint] = []
    private(set) var sparkMemory: [ChartPoint] = []
    private(set) var sparkDisk: [ChartPoint] = []
    private(set) var sparkNetwork: [ChartPoint] = []
    private(set) var sparkGPU: [ChartPoint] = []

    /// Detail series: meaning depends on `selection`.
    private(set) var primary: [ChartPoint] = []    // CPU total, memory used, disk read, net receive
    private(set) var secondary: [ChartPoint] = []  // CPU system, disk write, net send
    private(set) var perCore: [[ChartPoint]] = []  // index == core position in latest.cpu.cores
    private(set) var perDevice: [[ChartPoint]] = []
    private(set) var diskMax: Double = 1
    private(set) var networkMax: Double = 1

    @ObservationIgnored private var detailTick: ContinuousClock.Instant?
    @ObservationIgnored private var lastTick: ContinuousClock.Instant?

    func refresh(history: [SystemSnapshot], latest: SystemSnapshot?) {
        guard let latest else { return }
        if lastTick == latest.instant && detailTick == latest.instant { return }
        lastTick = latest.instant
        detailTick = latest.instant

        let xs: [Double] = history.map { Self.secondsAgo($0.instant, latest.instant) }
        sparkCPU = zip(xs, history).map { ChartPoint(x: $0, y: $1.cpu?.total ?? 0) }
        sparkMemory = zip(xs, history).map { x, s in
            ChartPoint(x: x, y: s.memory.map { $0.total == 0 ? 0 : Double($0.used) / Double($0.total) } ?? 0)
        }
        sparkDisk = zip(xs, history).map { ChartPoint(x: $0, y: ($1.disk?.readPerSec ?? 0) + ($1.disk?.writePerSec ?? 0)) }
        sparkNetwork = zip(xs, history).map { ChartPoint(x: $0, y: ($1.network?.receivedPerSec ?? 0) + ($1.network?.sentPerSec ?? 0)) }
        sparkGPU = zip(xs, history).map { ChartPoint(x: $0, y: $1.gpu?.utilization ?? 0) }

        switch selection {
        case .cpu:
            primary = sparkCPU
            secondary = zip(xs, history).map { x, s in
                let c = s.cpu
                let n = Double(max(1, c?.cores.count ?? 1))
                return ChartPoint(x: x, y: (c?.cores.reduce(0) { $0 + $1.system } ?? 0) / n)
            }
            let count = latest.cpu?.cores.count ?? 0
            perCore = (0..<count).map { i in
                zip(xs, history).map { x, s in
                    ChartPoint(x: x, y: (s.cpu?.cores.count ?? 0) > i ? s.cpu!.cores[i].total : 0)
                }
            }
        case .memory:
            primary = sparkMemory
        case .disk:
            primary = zip(xs, history).map { ChartPoint(x: $0, y: $1.disk?.readPerSec ?? 0) }
            secondary = zip(xs, history).map { ChartPoint(x: $0, y: $1.disk?.writePerSec ?? 0) }
            diskMax = Self.niceMax((primary + secondary).map(\.y).max() ?? 0)
        case .network:
            primary = zip(xs, history).map { ChartPoint(x: $0, y: $1.network?.receivedPerSec ?? 0) }
            secondary = zip(xs, history).map { ChartPoint(x: $0, y: $1.network?.sentPerSec ?? 0) }
            networkMax = Self.niceMax((primary + secondary).map(\.y).max() ?? 0)
        case .gpu:
            let count = latest.gpu?.devices.count ?? 0
            perDevice = (0..<count).map { i in
                zip(xs, history).map { x, s in
                    ChartPoint(x: x, y: (s.gpu?.devices.count ?? 0) > i ? s.gpu!.devices[i].utilization : 0)
                }
            }
        }
    }

    private static func secondsAgo(_ a: ContinuousClock.Instant, _ b: ContinuousClock.Instant) -> Double {
        let c = (a - b).components
        return Double(c.seconds) + Double(c.attoseconds) / 1e18
    }

    /// Rounds up to 1/2/5 x 10^n bytes/s (floor 1 MB/s) so the axis does not jitter every tick.
    private static func niceMax(_ v: Double) -> Double {
        let floor = 1_000_000.0
        guard v > floor else { return floor }
        let p = pow(10, (log10(v)).rounded(.down))
        for m in [1.0, 2, 5, 10] where m * p >= v { return m * p }
        return v
    }
}
