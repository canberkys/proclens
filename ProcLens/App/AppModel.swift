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
    /// Bumped whenever `grouper` / `runningApps` change; lets view models invalidate per-process caches.
    private(set) var appsRevision = 0
    /// True while the app window is on screen (not miniaturized, hidden or fully occluded).
    private(set) var isWindowVisible = true
    /// Same as `latest`, but only updated while the window is visible. Window views observe this one so a
    /// hidden window costs nothing per tick; the menu bar keeps using `latest` / `history`.
    private(set) var visibleSnapshot: SystemSnapshot?
    /// True while the menu bar panel is open; keeps the full sampler (processes, GPU, network) running even if the window is hidden.
    private(set) var isPanelOpen = false
    let protection = ProtectionPolicy()

    @ObservationIgnored private let processCollector = ProcessCollector(source: LiveProcessSource(), idleThrottling: true)
    /// Everything the window needs (processes, disk, network, GPU).
    @ObservationIgnored private let sampler: Sampler
    /// CPU + memory only: the menu bar graph and menu. Runs instead of `sampler` while the window is hidden,
    /// so a hidden app does not walk ~1,000 processes every second. Collectors are shared, so deltas stay valid.
    @ObservationIgnored private let lightSampler: Sampler
    @ObservationIgnored private var consumers: [Task<Void, Never>] = []
    @ObservationIgnored private var started = false
    @ObservationIgnored private var samplerSwitch: Task<Void, Never>?
    @ObservationIgnored private var appsRefreshPending = false
    @ObservationIgnored private var workspaceObservers: [NSObjectProtocol] = []

    init() {
        let host = LiveHostSource()
        let ioreg = LiveIORegistrySource()
        let cpu = CPUCollector(source: host)
        let memory = MemoryCollector(source: host)
        lightSampler = Sampler(interval: .default, cpu: cpu, memory: memory)
        sampler = Sampler(
            interval: .default,
            cpu: cpu,
            memory: memory,
            processes: processCollector,
            gpu: GPUCollector(source: ioreg),
            disk: DiskCollector(source: ioreg),
            network: NetworkCollector(source: LiveNetworkSource())
        )
        refreshRunningApps()
        observeWorkspace()
        observeWindowVisibility()
    }

    func start() {
        guard !started else { return }
        started = true
        for stream in [sampler.snapshots, lightSampler.snapshots] {
            consumers.append(Task { [weak self] in
                for await snapshot in stream {
                    self?.ingest(snapshot)
                }
            })
        }
        switchSampler()
    }

    func setInterval(_ newValue: SamplingInterval) {
        interval = newValue
        history.removeAll()
        let previous = samplerSwitch
        samplerSwitch = Task { [sampler, lightSampler] in
            await previous?.value
            await sampler.setInterval(newValue)
            await lightSampler.setInterval(newValue)
        }
    }

    /// Runs exactly one of the two samplers, chosen by window visibility. Serialized so rapid
    /// show/hide cannot leave both (or neither) running.
    private func switchSampler() {
        guard started else { return }
        let full = isWindowVisible || isPanelOpen
        let previous = samplerSwitch
        samplerSwitch = Task { [sampler, lightSampler, processCollector] in
            await previous?.value
            if full {
                await lightSampler.stop()
                await processCollector.reset()  // do not average rates over the hidden period
                await sampler.start()
            } else {
                await sampler.stop()
                await lightSampler.start()
            }
        }
    }

    func setPanelOpen(_ open: Bool) {
        guard open != isPanelOpen else { return }
        let before = isWindowVisible || isPanelOpen
        isPanelOpen = open
        if (isWindowVisible || isPanelOpen) != before { switchSampler() }
    }

    /// Full argv/env for the Details tab; read on demand, never on the hot path.
    func arguments(for id: ProcessID) async throws -> ProcArgs {
        try await processCollector.arguments(for: id)
    }

    /// Reads one process directly from libproc (one syscall). Used by actions so they work
    /// even when the current snapshot has no process table (window hidden, light sampler).
    func liveProcess(pid: pid_t) -> ProcessSample? {
        let source = LiveProcessSource()
        guard let info = try? source.taskAllInfo(pid) else { return nil }
        return ProcessSample(id: info.processID, ppid: info.ppid, uid: info.uid, name: info.name,
                             path: try? source.path(pid), threadCount: info.threadCount,
                             isTranslated: info.isTranslated, cpu: 0, memory: 0, diskReadPerSec: 0,
                             diskWritePerSec: 0, energy: 0, isRestricted: info.threadCount == 0)
    }

    /// True while `id` still names the same running process (guards against pid reuse).
    func isAlive(_ id: ProcessID) -> Bool {
        guard let info = try? LiveProcessSource().taskAllInfo(id.pid) else { return false }
        return info.startTime == id.startTime || info.startTime == 0
    }

    func icon(for pid: pid_t) -> NSImage? {
        NSRunningApplication(processIdentifier: pid)?.icon
    }

    // MARK: - Private

    private func ingest(_ snapshot: SystemSnapshot) {
        latest = snapshot
        if isWindowVisible { visibleSnapshot = snapshot }
        history.append(snapshot)
        let capacity = max(1, Int(Self.historySeconds / interval.rawValue))
        if history.count > capacity { history.removeFirst(history.count - capacity) }
    }

    private func refreshRunningApps() {
        let apps = NSWorkspace.shared.runningApplications.map {
            RunningAppInfo(pid: $0.processIdentifier, bundleIdentifier: $0.bundleIdentifier,
                           localizedName: $0.localizedName, isRegular: $0.activationPolicy == .regular)
        }
        let fresh = Dictionary(apps.map { ($0.pid, $0) }, uniquingKeysWith: { a, _ in a })
        guard fresh != runningApps else { return }
        // Only regular apps affect grouping and row names; other launches must not invalidate view caches.
        let oldRegular = Set(runningApps.values.filter(\.isRegular))
        runningApps = fresh
        if appsRevision == 0 || Set(apps.filter(\.isRegular)) != oldRegular {
            grouper = ProcessGrouper(apps: apps)
            appsRevision &+= 1
        }
    }

    /// Launch/terminate notifications come in bursts; refresh once after they settle.
    private func scheduleAppsRefresh() {
        guard !appsRefreshPending else { return }
        appsRefreshPending = true
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            self?.appsRefreshPending = false
            self?.refreshRunningApps()
        }
    }

    private func observeWindowVisibility() {
        let center = NotificationCenter.default
        let names: [Notification.Name] = [
            NSWindow.didChangeOcclusionStateNotification, NSWindow.didMiniaturizeNotification,
            NSWindow.didDeminiaturizeNotification, NSWindow.willCloseNotification,
            NSWindow.didBecomeKeyNotification, NSApplication.didHideNotification,
            NSApplication.didUnhideNotification,
        ]
        for name in names {
            workspaceObservers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                // Deferred a runloop turn so a closing window is already invisible when we look.
                Task { @MainActor in self?.updateWindowVisibility() }
            })
        }
    }

    private static let forceVisible = ProcessInfo.processInfo.environment["PROCLENS_FORCE_VISIBLE"] == "1"

    private func updateWindowVisibility() {
        // PROCLENS_FORCE_VISIBLE=1 disables occlusion gating (profiling on a screen that is asleep/covered).
        let visible = Self.forceVisible || !NSApp.isHidden && NSApp.windows.contains {
            $0.canBecomeMain && $0.isVisible && !$0.isMiniaturized && $0.occlusionState.contains(.visible)
        }
        guard visible != isWindowVisible else { return }
        let before = isWindowVisible || isPanelOpen
        isWindowVisible = visible
        if visible { visibleSnapshot = latest }
        if (isWindowVisible || isPanelOpen) != before { switchSampler() }
    }

    private func observeWorkspace() {
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            workspaceObservers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.scheduleAppsRefresh() }
            })
        }
    }
}

