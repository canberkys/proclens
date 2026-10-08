import Foundation
import Observation
import ProcLensCore

@Observable @MainActor
final class ServicesViewModel {
    private(set) var items: [LaunchdItemStatus] = []
    private(set) var isLoading = false
    private(set) var helperEnabled = false
    var error: String?
    var search = ""
    var runningOnly = false
    var showApple = true

    @ObservationIgnored private var services: AppServices?

    func bind(_ services: AppServices) { self.services = services }

    /// Loads, then refreshes every 5 s. Cancelled when the tab disappears, so nothing runs while hidden.
    func run() async {
        while !Task.isCancelled {
            await reload()
            try? await Task.sleep(for: .seconds(5))
        }
    }

    func reload() async {
        guard let services, !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        helperEnabled = services.helper.registrationStatus() == .enabled
        let snapshot = await services.launchd.snapshot()
        items = snapshot.items
        #if DEBUG
        if DemoMode.isActive { items = DemoLaunchd.relocated(items) }
        #endif
    }

    var filtered: [LaunchdItemStatus] {
        let q = search.trimmingCharacters(in: .whitespaces).lowercased()
        return items.filter { status in
            if runningOnly && !status.isRunning { return false }
            if !showApple && status.item.isApple { return false }
            guard !q.isEmpty else { return true }
            let item = status.item
            return item.label.lowercased().contains(q)
                || LaunchdPresentation.displayName(for: item).lowercased().contains(q)
                || item.effectiveProgram.lowercased().contains(q)
                || String(status.pid ?? -1) == q
        }
        .sorted { a, b in
            if a.isRunning != b.isRunning { return a.isRunning }
            return a.item.label.localizedCaseInsensitiveCompare(b.item.label) == .orderedAscending
        }
    }

    static func statusText(_ s: LaunchdItemStatus) -> (text: String, running: Bool) {
        if let pid = s.pid { return ("Running", pid > 0) }
        guard s.isLoaded else { return ("Not loaded", false) }
        if let code = s.lastExitStatus, code != 0 {
            return code < 0 ? ("Exited (signal \(-code))", false) : ("Exited (\(code))", false)
        }
        return ("Stopped", false)
    }

    // MARK: - Actions

    enum Op { case start, restart, stop }

    func perform(_ op: Op, _ status: LaunchdItemStatus) {
        guard let services else { return }
        let item = status.item
        Task {
            do {
                try LaunchdPresentation.preflight(item, helper: services.helper)
                let launchd = services.launchd
                switch op {
                case .start:
                    if !status.isLoaded { try await launchd.bootstrap(item) }
                    try await launchd.kickstart(item)
                case .restart:
                    if !status.isLoaded { try await launchd.bootstrap(item) }
                    try await launchd.kickstart(item, killRunning: true)
                case .stop:
                    // KeepAlive jobs would be relaunched after SIGTERM, so unload them instead.
                    if item.keepAlive != .never { try await launchd.bootout(item) } else { try await launchd.kill(item, signal: SIGTERM) }
                }
                error = nil
            } catch {
                self.error = "\(item.label): \(error.localizedDescription)"
            }
            try? await Task.sleep(for: .milliseconds(400))
            isLoading = false
            await reload()
        }
    }

    func info(for item: LaunchdItem) async -> Result<LaunchctlServiceInfo?, any Error> {
        guard let services else { return .success(nil) }
        if item.domain.isSystem, services.helper.registrationStatus() != .enabled {
            // `launchctl print system/<label>` usually needs root; still try, but explain on failure.
        }
        do { return .success(try await services.launchd.serviceInfo(for: item)) } catch { return .failure(error) }
    }
}
