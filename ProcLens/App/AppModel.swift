import AppKit
import Observation
import ProcLensCore

/// Owns the Sampler and is the single source of live data for every tab.
/// Views read from it; they never talk to collectors directly.
@Observable @MainActor
final class AppModel {
    /// Seconds of history kept for graphs.
    static let historySeconds: Double = 60

    private(set) var latest: SystemSnapshot?
    /// Oldest first; sized for `historySeconds` at the current interval.
    private(set) var history: [SystemSnapshot] = []
    private(set) var interval: SamplingInterval = .default
    private(set) var runningApps: [pid_t: RunningAppInfo] = [:]
    private(set) var grouper = ProcessGrouper(apps: [])
    let protection = ProtectionPolicy()

    @ObservationIgnored private let processCollector = ProcessCollector(source: LiveProcessSource())
    @ObservationIgnored private let sampler: Sampler
    @ObservationIgnored private var consumer: Task<Void, Never>?
    @ObservationIgnored private var workspaceObservers: [NSObjectProtocol] = []

    init() {
        let host = LiveHostSource()
        let ioreg = LiveIORegistrySource()
        sampler = Sampler(
            interval: .default,
            cpu: CPUCollector(source: host),
            memory: MemoryCollector(source: host),
            processes: processCollector,
            gpu: GPUCollector(source: ioreg),
            disk: DiskCollector(source: ioreg),
            network: NetworkCollector(source: LiveNetworkSource())
        )
        refreshRunningApps()
        observeWorkspace()
    }

    func start() {
        guard consumer == nil else { return }
        let stream = sampler.snapshots
        consumer = Task { [weak self] in
            for await snapshot in stream {
                self?.ingest(snapshot)
            }
        }
        Task { await sampler.start() }
    }

    func setInterval(_ newValue: SamplingInterval) {
        interval = newValue
        history.removeAll()
        Task { await sampler.setInterval(newValue) }
    }

    /// Full argv/env for the Details tab; read on demand, never on the hot path.
    func arguments(for id: ProcessID) async throws -> ProcArgs {
        try await processCollector.arguments(for: id)
    }

    func icon(for pid: pid_t) -> NSImage? {
        NSRunningApplication(processIdentifier: pid)?.icon
    }

    // MARK: - Private

    private func ingest(_ snapshot: SystemSnapshot) {
        latest = snapshot
        history.append(snapshot)
        let capacity = max(1, Int(Self.historySeconds / interval.rawValue))
        if history.count > capacity { history.removeFirst(history.count - capacity) }
    }

    private func refreshRunningApps() {
        let apps = NSWorkspace.shared.runningApplications.map {
            RunningAppInfo(pid: $0.processIdentifier, bundleIdentifier: $0.bundleIdentifier,
                           localizedName: $0.localizedName, isRegular: $0.activationPolicy == .regular)
        }
        runningApps = Dictionary(apps.map { ($0.pid, $0) }, uniquingKeysWith: { a, _ in a })
        grouper = ProcessGrouper(apps: apps)
    }

    private func observeWorkspace() {
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            workspaceObservers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refreshRunningApps() }
            })
        }
    }
}
