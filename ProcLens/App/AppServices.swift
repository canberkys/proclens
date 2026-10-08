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

    /// Latest process table seen (kept while the light sampler runs so on-demand scans still have pids).
    @ObservationIgnored private(set) var lastProcessTable: ProcessTable?

    init() {
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

    /// One listening-port scan over the latest process table (~1 ms for ~1,000 processes).
    func scanPorts() async -> [ListeningPort] {
        guard let table = lastProcessTable else { return [] }
        return await ports.scan(table: table)
    }

    func saveAlertRules(_ rules: [AlertRule]) throws {
        try alertStore.save(rules)
        Task { [alerts] in await alerts.setRules(rules) }
    }
}
