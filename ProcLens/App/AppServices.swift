import Foundation
import Observation
import ProcLensCore

/// Phase 2/3 services shared by the tabs. Owned by `AppModel`, fed from its snapshot stream.
/// Everything here is on demand or cheap per tick; heavy work stays in Core actors.
@Observable @MainActor
final class AppServices {
    /// 1 h tiered history (system totals + top-N processes). Fed only while process tables are sampled.
    @ObservationIgnored let history = ProcessHistory()
    /// Threshold rules; events are posted as notifications by the Alerts feature.
    @ObservationIgnored let alerts = AlertEngine()
    @ObservationIgnored let alertStore = AlertRuleStore()
    /// Listening sockets; scanned on demand by the Ports tab and the menu bar panel.
    @ObservationIgnored let ports = ListeningPortCollector()
    /// launchd jobs for the Startup and Services tabs; system-domain actions go through the helper.
    @ObservationIgnored let launchd = LaunchdService(privileged: HelperClient.shared)
    @ObservationIgnored let helper = HelperClient.shared
    /// True while the privileged helper is registered and approved. Views read it (tooltips, footers); it follows
    /// install/uninstall in Settings immediately and external changes within 30 s.
    private(set) var helperEnabled = false {
        didSet { ProcessesViewModel.helperEnabled = helperEnabled }
    }
    @ObservationIgnored private var helperPoll: Task<Void, Never>?

    /// Latest process table seen (kept while the light sampler runs so on-demand scans still have pids).
    @ObservationIgnored private(set) var lastProcessTable: ProcessTable?

    init() {
        helperEnabled = helper.registrationStatus() == .enabled
        ProcessesViewModel.helperEnabled = helperEnabled
        helperPoll = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30))
                self?.refreshHelperStatus()
            }
        }
        if let rules = try? alertStore.load() {
            Task { [alerts] in await alerts.setRules(rules) }
        }
    }

    func ingest(_ snapshot: SystemSnapshot) {
        if let table = snapshot.processes { lastProcessTable = table }
        Task { [history, alerts] in
            if snapshot.processes != nil { await history.record(snapshot) }
            _ = await alerts.evaluate(snapshot)
        }
    }

    /// Re-reads the helper registration (bypassing the 10 s cache). Cheap; called every 30 s and after Settings changes.
    func refreshHelperStatus() {
        let enabled = helper.registrationStatus(forceRefresh: true) == .enabled
        if enabled != helperEnabled { helperEnabled = enabled }
    }

    /// One listening-port scan over the latest process table (~1 ms for ~1,000 processes). With the helper
    /// enabled, one extra XPC call lists the sockets of the processes this app cannot read.
    func scanPorts() async -> [ListeningPort] {
        guard let table = lastProcessTable else { return [] }
        if helper.isEnabled {
            let pids = table.processes.values.filter { ($0.isRestricted || $0.viaHelper) && $0.pid > 0 }.map(\.pid)
            if !pids.isEmpty, let sockets = try? await helper.listListeningSockets(pids: pids) {
                await ports.setHelperPorts(ListeningPortCollector.helperPorts(from: sockets, table: table))
            }
        } else {
            await ports.setHelperPorts([])
        }
        return await ports.scan(table: table)
    }

    func saveAlertRules(_ rules: [AlertRule]) throws {
        try alertStore.save(rules)
        Task { [alerts] in await alerts.setRules(rules) }
    }
}
