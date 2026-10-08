import Foundation
import Observation
import ProcLensCore

enum StartupFilter: String, CaseIterable, Identifiable {
    case all = "All", user = "User", system = "System", apple = "Apple"
    var id: String { rawValue }
}

@Observable @MainActor
final class StartupViewModel {
    private(set) var items: [LaunchdItemStatus] = []
    private(set) var invalid: [InvalidLaunchdPlist] = []
    private(set) var loginItems: [BackgroundItem] = []
    private(set) var warnings: [String] = []
    private(set) var isLoading = false
    private(set) var helperEnabled = false
    private(set) var signing: [String: CodeSignStatus] = [:]
    var error: String?

    var search = ""
    var filter: StartupFilter = .all
    var showApple = false

    /// Signer-derived vendor per item id; applied in one batch so the list regroups once.
    private(set) var signerVendor: [String: String] = [:]
    @ObservationIgnored private var teamVendor: [String: String] = [:]
    @ObservationIgnored private var vendorTask: Task<Void, Never>?
    @ObservationIgnored private var services: AppServices?
    @ObservationIgnored private var signing_inflight: Set<String> = []

    func bind(_ services: AppServices) { self.services = services }

    /// Loads once, then reloads when the plist directories change. Cancel to stop watching.
    func run() async {
        await reload()
        let dirs = LaunchdDirectory.standard().map(\.url)
        for await _ in LaunchdDirectoryWatcher.changes(in: dirs, latency: 1.0) {
            if Task.isCancelled { break }
            await reload()
        }
    }

    func reload() async {
        guard let services, !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        defer { resolveSignerVendors() }
        helperEnabled = services.helper.registrationStatus() == .enabled
        let snapshot = await services.launchd.snapshot()
        items = snapshot.items
        #if DEBUG
        if DemoMode.isActive { items = DemoLaunchd.relocated(items) }
        #endif
        invalid = snapshot.invalid
        warnings = snapshot.warnings
        #if DEBUG
        let useHelperItems = helperEnabled && !DemoMode.isActive
        #else
        let useHelperItems = helperEnabled
        #endif
        if useHelperItems {
            let background = (try? await services.helper.backgroundItems()) ?? []
            loginItems = background.filter { item in
                switch item.type { case .loginItem, .app: item.developerName != "Apple"; default: false }
            }
        } else {
            loginItems = []
        }
        #if DEBUG
        await LaunchdSelfTest.runIfRequested(services: services)
        #endif
    }

    // MARK: - Filtering / grouping

    struct Group: Identifiable {
        var vendor: String
        var items: [LaunchdItemStatus]
        var id: String { vendor }
    }

    var filtered: [LaunchdItemStatus] {
        let q = search.trimmingCharacters(in: .whitespaces).lowercased()
        return items.filter { status in
            let item = status.item
            switch filter {
            case .all: if item.isApple && !showApple { return false }
            case .user: if item.scope != .userAgent { return false }
            case .system: if item.scope != .globalAgent && item.scope != .globalDaemon { return false }
            case .apple: if !item.isApple { return false }
            }
            guard !q.isEmpty else { return true }
            return item.label.lowercased().contains(q)
                || LaunchdPresentation.displayName(for: item).lowercased().contains(q)
                || item.effectiveProgram.lowercased().contains(q)
                || (item.vendor ?? "").lowercased().contains(q)
        }
    }

    var groups: [Group] {
        let dict = Dictionary(grouping: filtered) { vendor(for: $0.item) }
        return dict.map { Group(vendor: $0.key, items: $0.value.sorted {
            LaunchdPresentation.displayName(for: $0.item).localizedCaseInsensitiveCompare(LaunchdPresentation.displayName(for: $1.item)) == .orderedAscending
        }) }
        .sorted { a, b in
            if a.vendor == "Other" { return false }
            if b.vendor == "Other" { return true }
            return a.vendor.localizedCaseInsensitiveCompare(b.vendor) == .orderedAscending
        }
    }

    private func vendor(for item: LaunchdItem) -> String {
        if item.isApple { return LaunchdPresentation.vendor(for: item) }
        return signerVendor[item.id] ?? LaunchdPresentation.vendor(for: item)
    }

    /// Resolves the signing developer for every non-Apple item in the background (cached by team ID),
    /// then publishes all results at once.
    private func resolveSignerVendors() {
        vendorTask?.cancel()
        let candidates = items.map(\.item).filter { !$0.isApple && !$0.isInterpreterLaunch && $0.signablePath != nil }
        var known = teamVendor
        vendorTask = Task {
            var result: [String: String] = [:]
            for item in candidates {
                if Task.isCancelled { return }
                guard let path = item.signablePath else { continue }
                #if DEBUG
                if DemoMode.isActive, let vendor = DemoMode.signerVendor(forPath: path) { result[item.id] = vendor; continue }
                #endif
                let status = await SigningLookup.status(forPath: path)
                let team: String?
                switch status {
                case .developerID(let t, _), .appStore(let t): team = t
                case .apple: result[item.id] = "Apple"; continue
                default: continue
                }
                if let team, let name = known[team] { result[item.id] = name; continue }
                guard let leaf = await SigningLookup.details(forPath: path)?.certificateChain.first,
                      let name = VendorGuess.vendorName(fromCertificateCommonName: leaf) else { continue }
                if let team { known[team] = name }
                result[item.id] = name
            }
            if Task.isCancelled { return }
            teamVendor = known
            if result != signerVendor { signerVendor = result }
        }
    }

    var visibleLoginItems: [BackgroundItem] {
        guard filter == .all || filter == .user else { return [] }
        let q = search.trimmingCharacters(in: .whitespaces).lowercased()
        return q.isEmpty ? loginItems : loginItems.filter { $0.name.lowercased().contains(q) }
    }

    // MARK: - Signing (lazy)

    func signingStatus(for item: LaunchdItem) -> CodeSignStatus? { item.signing ?? signing[item.id] }

    func loadSigning(for item: LaunchdItem) {
        if item.isInterpreterLaunch { if signing[item.id] == nil { signing[item.id] = .unsigned }; return }
        guard item.signing == nil, signing[item.id] == nil, let path = item.signablePath,
              signing_inflight.insert(item.id).inserted else { return }
        Task {
            let status = await SigningLookup.status(forPath: path)
            signing[item.id] = status
            signing_inflight.remove(item.id)
        }
    }

    // MARK: - Actions

    func setEnabled(_ enabled: Bool, _ status: LaunchdItemStatus) {
        guard let services else { return }
        let item = status.item
        Task {
            do {
                try LaunchdPresentation.preflight(item, helper: services.helper)
                if enabled {
                    try await services.launchd.enable(item)
                } else {
                    try await services.launchd.disable(item)
                }
                error = nil
            } catch {
                self.error = "\(item.label): \(error.localizedDescription)"
            }
            await reload()
        }
    }
}
